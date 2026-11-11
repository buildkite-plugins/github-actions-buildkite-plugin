#!/usr/bin/env python3
"""Opt-in hosted comparison. All agent and HTTP calls use real services."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

URL = "https://github.com/buildkite/buildkite-gha/releases/download/v0.129.0/buildkite-gha_linux_x86_64"
SHA = "87abdffbafc6e91256552f97d13138982804802a7370bd096c033658902f0bef"
SCRIPT = Path(__file__).resolve()
REPO = SCRIPT.parent.parent


def agent(*args, **kwargs):
    return subprocess.check_output([os.environ.get("PROOF_REAL_AGENT", "buildkite-agent"), *args], **kwargs)


def prepare():
    with tempfile.TemporaryDirectory(prefix="pinned-runtime-import-") as temporary:
        root = Path(temporary)
        binary = root / "buildkite-gha"
        with urllib.request.urlopen(URL) as response:
            binary.write_bytes(response.read())
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == SHA
        binary.chmod(0o700)
        # Capture only the emitted pipeline. Artifact uploads go to the real agent.
        os.environ["PROOF_REAL_AGENT"] = shutil.which("buildkite-agent")
        os.environ["PROOF_ROOT"] = str(root)
        wrapper = root / "buildkite-agent"
        wrapper.write_text(f'#!/bin/sh\nexec python3 "{SCRIPT}" capture "$@"\n')
        wrapper.chmod(0o700)
        env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', BUILDKITE_GHA_TELEMETRY_DISABLED="true")
        subprocess.run([str(binary), "upload", "--runner-queue", "ubuntu-latest=hosted", ".buildkite/fixtures/pinned-runtime-proof.yml"], env=env, check=True)
        pipeline = (root / "pipeline.yml").read_text()
        assert len(re.findall(r'^\s+BUILDKITE_GHA_PLAN_DIGEST: "sha256:[0-9a-f]{64}"$', pipeline, re.M)) == 1, "expected one admitted plan, not a failure or skipped workflow"
        commands = re.findall(r'^\s+command: (".*")$', pipeline, re.M)
        assert len(commands) == 1, "expected one executable job"
        legacy = root / "legacy.sh"
        legacy.write_text(json.loads(commands[0]))
        agent("artifact", "upload", "legacy.sh", cwd=root)
        producer = os.environ["BUILDKITE_JOB_ID"]
        assert re.fullmatch(r"[0-9a-f-]{36}", producer)
        command = f"python3 .buildkite/pinned-runtime-proof.py run {producer}"
        pipeline = pipeline.replace("command: " + commands[0], "command: " + json.dumps(command), 1)
        # Check out the exact candidate so the hook and proof code are available.
        pipeline = pipeline.replace("skip: true", "skip: false")
        agent("pipeline", "upload", "--no-interpolation", input=pipeline.encode())


def capture():
    if sys.argv[2:4] == ["pipeline", "upload"]:
        (Path(os.environ["PROOF_ROOT"]) / "pipeline.yml").write_bytes(sys.stdin.buffer.read())
    else:
        os.execv(os.environ["PROOF_REAL_AGENT"], [os.environ["PROOF_REAL_AGENT"], *sys.argv[2:]])


def probe():
    parent = os.getppid()
    while True:
        args = Path(f"/proc/{parent}/cmdline").read_bytes().split(b"\0")
        if b"--plan" in args:
            break
        parent = int(Path(f"/proc/{parent}/stat").read_text().split()[3])
    binary = os.readlink(f"/proc/{parent}/exe")
    plan = os.fsdecode(args[args.index(b"--plan") + 1])
    assert not os.access(binary, os.W_OK) and not os.access(plan, os.W_OK)
    env = dict(os.fsdecode(item).split("=", 1) for item in Path(f"/proc/{parent}/environ").read_bytes().split(b"\0") if b"=" in item)
    assert env.get("BUILDKITE_AGENT_ACCESS_TOKEN")
    assert "BUILDKITE_AGENT_ACCESS_TOKEN" not in os.environ
    assert env.get("BUILDKITE_AGENT_JOB_API_SOCKET"), "real Job API socket required"
    # Only request a harmless named value; never print or dump job credentials.
    key = subprocess.check_output(["buildkite-agent", "env", "get", "BUILDKITE_STEP_KEY"], env=env, text=True).strip()
    assert key == env["BUILDKITE_STEP_KEY"]
    print(f"PROOF runtime_mode={os.stat(binary).st_mode & 0o777:o} plan_mode={os.stat(plan).st_mode & 0o777:o}")
    print("PROOF job_api=real-env-get-passed token=runtime-only")


def execute(producer):
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    assert commit == os.environ["BUILDKITE_COMMIT"]
    print(f"PROOF candidate={commit} runtime_sha256={SHA}", flush=True)
    digest = os.environ["BUILDKITE_GHA_PLAN_DIGEST"]
    print(f"PROOF plan={digest} producer={producer}", flush=True)
    shutil.copyfile(SCRIPT, "/tmp/pinned-runtime-proof.py")
    with tempfile.TemporaryDirectory(prefix="pinned-runtime-proof-") as temporary:
        root = Path(temporary)
        agent("artifact", "download", "legacy.sh", str(root), "--step", producer)
        transport = root / "transport"
        transport.mkdir()
        real_curl = shutil.which("curl")
        wrapper = transport / "curl"
        wrapper.write_text(f'#!/bin/bash\nprintf "%s\\n" "${{12}}" >> "$PROOF_CURL_LOG"\nexec "{real_curl}" "$@"\n')
        wrapper.chmod(0o755)
        config = {"run": {"plan": {"digest": digest, "producer": producer}, "runtime": {"platform": "linux/amd64", "url": URL, "sha256": SHA}, "hosted-tool-cache": True}}
        observations = {}
        for name, expected, downloads in [("legacy", 0, 0), ("cold", 0, 1), ("warm", 0, 0), ("legacy-failure", 1, 0), ("pinned-failure", 1, 0), ("bad-digest", 1, 1)]:
            Path("/tmp/pinned-runtime-proof-exit").write_text("37" if "failure" in name else "0")
            selected = json.loads(json.dumps(config))
            if name == "bad-digest":
                selected["run"]["runtime"]["sha256"] = "0" * 64
            log = root / "curl.log"
            log.write_text("")
            env = dict(os.environ, PATH=f'{transport}:{os.environ["PATH"]}', PROOF_CURL_LOG=str(log),
                       BUILDKITE_GHA_CACHE_DIR=str(root / "cache"), BUILDKITE_PLUGIN_CONFIGURATION=json.dumps(selected), BUILDKITE_GHA_TELEMETRY_DISABLED="true")
            command = ["bash", str(root / "legacy.sh")] if name.startswith("legacy") else [str(REPO / "hooks/command")]
            result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(f"--- {name}: status={result.returncode} expected={expected}", flush=True)
            print(result.stdout, flush=True)
            assert result.returncode == expected, name
            requests = log.read_text().splitlines()
            assert len(requests) == downloads and all(url == URL for url in requests), requests
            print(f"PROOF {name} downloads={len(requests)} release_lookups=0", flush=True)
            observations[name] = [line for line in result.stdout.splitlines() if line.startswith("PROOF ")]
            if name == "bad-digest":
                assert "checksum verification failed" in result.stdout and not observations[name]
            else:
                assert "PROOF job_api=real-env-get-passed token=runtime-only" in observations[name]
                assert "PROOF output=hello-from-saved-plan" in observations[name]
        assert observations["legacy"] == observations["cold"] == observations["warm"]
        assert observations["legacy-failure"] == observations["pinned-failure"]
        print("PROOF PASS: same saved plan, real artifacts, real Job API, identity, permissions, status, cold/warm and bad digest", flush=True)


def platforms():
    """Test the plugin before a released importer emits the expanded contract."""
    assert os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
    version = os.environ.get("PINNED_PROOF_VERSION", "0.133.0")
    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
    plugin_ref = os.environ.get("PINNED_PROOF_PLUGIN_REF", os.environ["BUILDKITE_COMMIT"])
    assert re.fullmatch(r"[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+", plugin_ref)
    source = os.environ.get("PINNED_PROOF_PLAN_SOURCE", "producer")
    assert source in ("producer", "inline", "env")
    repository = os.environ.get("PINNED_PROOF_REPOSITORY", "buildkite-plugins/github-actions-buildkite-plugin")
    assert re.fullmatch(r"[\w.-]+/[\w.-]+", repository)
    owner, name = repository.split("/")
    producer = os.environ["BUILDKITE_JOB_ID"]
    endpoint = os.environ["BUILDKITE_AGENT_ENDPOINT"].rstrip("/")
    assert endpoint.startswith("https://")
    request = urllib.request.Request(f"{endpoint}/jobs/{producer}/github-actions/releases/tags/v{version}",
                                     headers={"Authorization": "Token " + os.environ["BUILDKITE_AGENT_ACCESS_TOKEN"]})
    with urllib.request.urlopen(request) as response:
        release = json.load(response)
    assert release["tag_name"] == "v" + version
    names = {"linux/amd64": "linux_x86_64", "linux/arm64": "linux_arm64",
             "darwin/arm64": "darwin_arm64", "windows/amd64": "windows_x86_64.exe"}
    assets = {}
    for platform, suffix in names.items():
        matches = [asset for asset in release["assets"] if asset["name"] == "buildkite-gha_" + suffix]
        assert len(matches) == 1
        asset = matches[0]
        assert asset["browser_download_url"].startswith("https://")
        assert re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"])
        assets[platform] = asset
    with tempfile.TemporaryDirectory(prefix="platform-runtime-import-") as temporary:
        root = Path(temporary)
        binary = root / "buildkite-gha"
        with urllib.request.urlopen(assets["linux/amd64"]["browser_download_url"]) as response:
            binary.write_bytes(response.read())
        assert "sha256:" + hashlib.sha256(binary.read_bytes()).hexdigest() == assets["linux/amd64"]["digest"]
        binary.chmod(0o700)
        event = root / "event.json"
        event.write_text(json.dumps({"provider": "github", "event": "workflow_dispatch",
            "repository": {"owner": owner, "name": name,
                           "clone_url": "https://github.com/" + repository + ".git", "default_branch": "main"},
            "ref": "refs/heads/" + os.environ["BUILDKITE_BRANCH"], "sha": os.environ["BUILDKITE_COMMIT"],
            "actor": "buildkite-gha-proof", "payload": {"inputs": {"marker": "platform-proof"}}}))
        os.environ["PROOF_REAL_AGENT"] = shutil.which("buildkite-agent")
        os.environ["PROOF_ROOT"] = str(root)
        wrapper = root / "buildkite-agent"
        wrapper.write_text(f'#!/bin/sh\nexec python3 "{SCRIPT}" capture "$@"\n')
        wrapper.chmod(0o700)
        env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', BUILDKITE_GHA_PLUGIN_RELEASE=json.dumps(release))
        arguments = [str(binary), "upload", "--event-path", str(event)]
        for label, key in [("ubuntu-latest", "LINUX"), ("ubuntu-24.04-arm", "ARM"), ("macos-14", "MAC"), ("windows-2022", "WINDOWS")]:
            arguments += ["--runner-queue", label + "=" + os.environ["PINNED_PROOF_" + key + "_QUEUE"]]
        for platform, asset in assets.items():
            if platform == "linux/amd64":
                continue
            counterpart = root / asset["name"]
            with urllib.request.urlopen(asset["browser_download_url"]) as response:
                counterpart.write_bytes(response.read())
            assert "sha256:" + hashlib.sha256(counterpart.read_bytes()).hexdigest() == asset["digest"]
            counterpart.chmod(0o700)
            arguments += ["--runtime-distribution", platform + "=" + str(counterpart)]
        subprocess.run([*arguments, ".github/workflows/pinned-runtime-platforms.yml"], env=env, check=True)
        pipeline = json.loads(agent("pipeline", "upload", "--dry-run", "--no-interpolation", "--format", "json", str(root / "pipeline.yml")))
        steps = [job for group in pipeline["steps"] for job in group.get("steps", [group])]
        records = []
        for step in steps:
            digest = step.get("env", {}).get("BUILDKITE_GHA_PLAN_DIGEST")
            assert digest, "expected an admitted executable plan"
            path = ".buildkite-gha/plans/" + digest.removeprefix("sha256:") + ".json"
            agent("artifact", "download", path, str(root), "--step", producer)
            plan_bytes = (root / path).read_bytes()
            assert "sha256:" + hashlib.sha256(plan_bytes).hexdigest() == digest
            plan = json.loads(plan_bytes)
            platform = next(platform for platform, asset in assets.items() if asset["digest"] == plan["runtime"]["distribution_digest"])
            asset = assets[platform]
            run = {"plan": {"digest": digest, "producer": producer},
                   "runtime": {"platform": platform, "url": asset["browser_download_url"], "sha256": asset["digest"][7:]},
                   "hosted-tool-cache": platform == "darwin/arm64" or bool(step.get("image"))}
            if source != "producer":
                run["plan"] = {"digest": digest, "inline": base64.b64encode(plan_bytes).decode()}
                event_path = ".buildkite-gha/events/" + plan["event"]["payload_digest"][7:] + ".json"
                agent("artifact", "download", event_path, str(root), "--step", producer)
                payload = base64.b64encode((root / event_path).read_bytes()).decode()
                if source == "env":
                    run["event"] = {"env": "BUILDKITE_GHA_EVENT_PAYLOAD"}
                    step.setdefault("env", {})["BUILDKITE_GHA_EVENT_PAYLOAD"] = payload
                else:
                    run["event"] = {"inline": payload}
            # The plugin-stage proof deliberately changes only delivery. Later
            # importer proofs must submit their emitted steps without rewriting.
            step.pop("command", None)
            step["plugins"] = [{"github-actions#" + plugin_ref: {"run": run}}]
            step.setdefault("env", {})["BUILDKITE_PLUGIN_VALIDATION"] = "true"
            records.append({"key": step["key"], "platform": platform, "plan": digest, "source": source,
                            "runtime": asset["digest"], "event": plan["event"]["payload_digest"]})
        assert len(records) == 8 and {r["platform"] for r in records} == set(names)
        receipt = root / "platform-runtime-plans.json"
        receipt.write_text(json.dumps(records, indent=2))
        agent("artifact", "upload", receipt.name, cwd=root)
        agent("pipeline", "upload", "--no-interpolation", input=json.dumps(pipeline).encode())
        print(f"Scheduled {len(records)} native jobs with plugin {plugin_ref}, runtime v{version}, source={source}")


if __name__ == "__main__":
    {"import": prepare, "capture": capture, "probe": probe, "platforms": platforms, "run": lambda: execute(sys.argv[2])}[sys.argv[1]]()
