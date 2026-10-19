#!/usr/bin/env python3
"""HandTodo release pipeline. Standard library only; never publishes or pushes Git changes."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import io
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = "windows-package.yml"
CATALOG = ["01-cat", "02-rocket", "03-ufo", "04-boat", "05-coffee"]

class PackageError(Exception):
    pass

def version_value(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise PackageError("版本号须为三段数字，例如 0.2.1")
    return value

def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def git(*args, required=True):
    p = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if p.returncode and required:
        raise PackageError("Git 检查失败：" + p.stderr.strip())
    return p.stdout.strip() if not p.returncode else ""

def source_fingerprint():
    paths = [ROOT / "VERSION", ROOT / "build.sh"]
    for folder in ["Sources", "Windows", "Resources", "Distribution", ".github"]:
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and not any(part in {"bin", "obj", "output", "__pycache__"} for part in path.relative_to(ROOT).parts):
                paths.append(path)
    h = hashlib.sha256()
    for path in sorted(paths):
        if path.is_file():
            h.update(str(path.relative_to(ROOT)).encode()); h.update(digest(path).encode())
    return h.hexdigest()

@contextmanager
def release_lock():
    lock = ROOT / "build/packaging.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a+b") as f:
        if f.tell() == 0:
            f.write(b"0"); f.flush()
        f.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise PackageError("已有打包任务正在运行，不能同时改写构建目录") from None
        try:
            yield
        finally:
            if os.name == "nt":
                import msvcrt
                f.seek(0); msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)

def source_info():
    return {"commit": git("rev-parse", "HEAD", required=False) or None,
            "branch": git("rev-parse", "--abbrev-ref", "HEAD", required=False) or None,
            "dirty": bool(git("status", "--porcelain", "--untracked-files=normal", required=False))}

def repository():
    remote = git("remote", "get-url", "origin")
    m = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?", remote)
    if not m:
        raise PackageError("Windows 云端验证需要 GitHub origin 仓库")
    return m.group(1)

def github_token():
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    p = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
                       input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True,
                       env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, timeout=30)
    values = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    if not values.get("password"):
        raise PackageError("未找到 GitHub 凭据，无法执行 Windows 原生验证；可配置 GH_TOKEN，或在 Windows 本机运行")
    return values["password"]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class GitHub:
    def __init__(self, repo):
        self.base = "https://api.github.com/repos/" + repo
        self.headers = {"Authorization": "Bearer " + github_token(), "Accept": "application/vnd.github+json",
                        "X-GitHub-Api-Version": "2022-11-28"}

    def request(self, path, data=None):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(self.base + path, data=body, headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                payload = r.read()
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as e:
            raise PackageError("GitHub 请求失败 (HTTP %d)：%s" % (e.code, path)) from None
        except (OSError, ValueError) as e:
            raise PackageError("GitHub 验证请求失败：" + type(e).__name__) from None

    def artifact(self, url):
        # Never forward the GitHub token to redirected blob-storage hosts.
        if not url.startswith(self.base + "/actions/artifacts/"):
            raise PackageError("不接受仓库以外的 artifact 地址")
        request = urllib.request.Request(url, headers=self.headers)
        opener = urllib.request.build_opener(NoRedirect())
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as e:
            if e.code != 302:
                raise PackageError("读取验证报告失败 (HTTP %d)" % e.code) from None
            location = e.headers.get("Location", "")
            if urllib.parse.urlparse(location).scheme != "https":
                raise PackageError("验证报告下载地址必须使用 HTTPS")
            response = urllib.request.urlopen(location, timeout=30)
        with response:
            payload = response.read(10 * 1024 * 1024 + 1)
        if len(payload) > 10 * 1024 * 1024:
            raise PackageError("验证报告超过大小上限")
        return payload

def check_windows_report(payload, destination):
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        results = [n for n in archive.namelist() if Path(n).name == "result.txt"]
        if len(results) != 1:
            raise PackageError("Windows artifact 缺少唯一的 result.txt")
        result = archive.read(results[0]).decode("utf-8-sig").strip()
        if not result.startswith("PASS:"):
            raise PackageError("Windows 原生检查未通过：" + result[:200])
        destination.mkdir(parents=True, exist_ok=True)
        for entry in archive.infolist():
            if Path(entry.filename).name in ("result.txt", "windows-preview.png"):
                if entry.file_size > 5 * 1024 * 1024:
                    raise PackageError("Windows 报告文件过大")
                (destination / Path(entry.filename).name).write_bytes(archive.read(entry))
    return result

def verify_windows_github(source, version, output, wait_seconds):
    if not source["commit"] or source["dirty"]:
        raise PackageError("Windows 云端验证要求干净且已同步的提交；先保存并同步源码，打包工具不会自动提交或推送")
    repo = repository()
    api = GitHub(repo)
    commit = source["commit"]
    deadline = time.monotonic() + wait_seconds
    dispatched = False
    previous_run_ids = set()
    watched_run_id = None
    previous = None
    while True:
        path = "/actions/workflows/%s/runs?head_sha=%s&per_page=20" % (WORKFLOW, commit)
        runs = api.request(path)["workflow_runs"]
        successful = next((r for r in runs if r["head_sha"] == commit and r["status"] == "completed" and r["conclusion"] == "success"), None)
        if successful:
            artifacts = api.request("/actions/runs/%s/artifacts" % successful["id"])["artifacts"]
            report = next((a for a in artifacts if a["name"] == "windows-native-test-report" and not a["expired"]), None)
            if report:
                text = check_windows_report(api.artifact(report["archive_download_url"]), output / "windows-native-test")
                return {"status": "passed", "method": "github-actions-native-windows", "source_commit": commit,
                        "run_url": successful["html_url"], "result": text,
                        "scope": "Native tests of the same source commit; executable cross-built locally"}
        running = next((r for r in runs if r["head_sha"] == commit and r["status"] != "completed"), None)
        if running:
            watched_run_id = running["id"]
        if watched_run_id:
            failed = next((r for r in runs if r["id"] == watched_run_id and r["status"] == "completed" and r["conclusion"] != "success"), None)
            if failed:
                raise PackageError("Windows 原生检查失败：" + failed["html_url"])
        if not running and not dispatched:
            branch = source["branch"]
            if not branch or branch == "HEAD":
                raise PackageError("无法为游离 HEAD 触发 Windows 验证；请使用已同步的分支")
            remote = git("ls-remote", "origin", "refs/heads/" + branch)
            if not remote or remote.split()[0] != commit:
                raise PackageError("当前分支尚未同步到远程，无法验证同一提交；打包工具不会自动推送")
            print("触发 Windows 原生检查（当前提交）", flush=True)
            previous_run_ids = {r["id"] for r in runs}
            api.request("/actions/workflows/%s/dispatches" % WORKFLOW, {"ref": branch, "inputs": {"version": version}})
            dispatched = True
        current = running["status"] if running else "等待 Windows 任务启动"
        if current != previous:
            print("Windows 验证：" + current, flush=True)
            previous = current
        if dispatched and runs and not running:
            latest = runs[0]
            if latest["id"] not in previous_run_ids and latest["head_sha"] == commit and latest["status"] == "completed" and latest["conclusion"] not in ("success", None):
                raise PackageError("Windows 原生检查失败：" + latest["html_url"])
        if time.monotonic() >= deadline:
            raise PackageError("Windows 原生检查等待超时；未将产物标记为已验证")
        time.sleep(15)

class Pipeline:
    def __init__(self, args):
        self.args = args
        self.version = version_value(args.version or (ROOT / "VERSION").read_text().strip())
        self.source = source_info()
        self.source["tree_sha256"] = source_fingerprint()
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        self.run_id = stamp + "-" + (self.source["commit"] or "local")[:8]
        self.output = ROOT / "Distribution/output" / self.version / self.run_id
        self.work = ROOT / "build/packaging" / self.run_id
        self.manifest = {"schema_version": 1, "app": "HandTodo", "version": self.version, "run_id": self.run_id,
                         "created_at": dt.datetime.now(dt.timezone.utc).isoformat(), "source": self.source,
                         "status": "planned", "artifacts": [], "verification": {},
                         "signing": {"macos": "ad-hoc; not notarized", "windows": "unsigned"}}

    @property
    def platforms(self):
        return ["macos", "windows"] if self.args.platform == "all" else [self.args.platform]

    def preflight(self):
        tools = ["git"]
        if "macos" in self.platforms:
            if sys.platform != "darwin":
                raise PackageError("macOS 打包需要在 Mac 上运行")
            tools += ["swiftc", "xcrun", "lipo", "codesign", "hdiutil", "ditto"]
        if "windows" in self.platforms:
            tools += ["dotnet"]
        missing = sorted(set(t for t in tools if not shutil.which(t)))
        if missing:
            raise PackageError("缺少构建工具：" + ", ".join(missing))
        for name in ["hand.png", "hand-height.png", *("Doodles/" + n + ".png" for n in CATALOG)]:
            if not (ROOT / "Resources" / name).is_file():
                raise PackageError("缺少素材：" + name)
        if "windows" in self.platforms:
            sdk = subprocess.run(["dotnet", "--list-sdks"], capture_output=True, text=True, check=True).stdout
            if not re.search(r"(?m)^8\.", sdk):
                raise PackageError("Windows 构建需要 .NET 8 SDK")
        return {"platforms": self.platforms, "version": self.version, "source": self.source,
                "windows_test": self.args.windows_test, "output": str(self.output)}

    def run(self, args, log_name, env=None):
        log = self.output / "logs" / (log_name + ".txt")
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("w") as f:
            p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        if p.returncode:
            tail = "\n".join(log.read_text(errors="replace").splitlines()[-15:])
            raise PackageError("步骤失败：%s\n%s\n日志：%s" % (log_name, tail, log))
        return log.read_text(errors="replace")

    def add_artifact(self, platform_name, path):
        self.manifest["artifacts"].append({"platform": platform_name, "file": path.name, "bytes": path.stat().st_size,
                                            "sha256": digest(path)})

    def macos(self):
        print("Mac：构建 Apple 芯片 + Intel 通用版", flush=True)
        self.run([ROOT / "build.sh"], "macos-build", {**os.environ, "HANDTODO_VERSION": self.version})
        app = ROOT / "build/掌上待办.app"
        exe = app / "Contents/MacOS/HandTodo"
        with (app / "Contents/Info.plist").open("rb") as f:
            if plistlib.load(f)["CFBundleShortVersionString"] != self.version:
                raise PackageError("Mac 应用内部版本与打包版本不一致")
        architectures = self.run(["lipo", "-archs", exe], "macos-architectures").split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise PackageError("Mac 可执行文件不是双架构通用版")
        self.run(["codesign", "--verify", "--deep", "--strict", app], "macos-signature")
        self.run([exe, "--self-test"], "macos-native-tests")
        tests = {"native": "passed", "other_architecture": "not-executed"}
        if platform.machine() == "arm64":
            probe = subprocess.run(["arch", "-x86_64", "/usr/bin/true"], capture_output=True)
            if probe.returncode == 0:
                self.run(["arch", "-x86_64", exe, "--self-test"], "macos-intel-tests")
                tests["other_architecture"] = "passed-under-Rosetta"
        stage = self.work / "macos-stage"
        stage.mkdir(parents=True)
        self.run(["ditto", app, stage / app.name], "macos-stage")
        (stage / "Applications").symlink_to("/Applications")
        instructions = (ROOT / "Distribution/使用说明-Mac.txt").read_text().replace("{{VERSION}}", self.version)
        (stage / "使用说明.txt").write_text(instructions)
        dmg = self.output / ("HandTodo-%s-macOS-Universal.dmg" % self.version)
        self.run(["hdiutil", "create", "-volname", "掌上待办", "-srcfolder", stage, "-format", "UDZO", dmg], "macos-dmg")
        self.run(["hdiutil", "verify", dmg], "macos-dmg-integrity")
        self.manifest["verification"]["macos"] = {"status": "passed", "architectures": architectures, "tests": tests,
                                                    "disk_image": "verified", "code_signature": "ad-hoc-verified"}
        self.add_artifact("macos", dmg)

    def windows(self):
        print("Windows：构建自带运行时的 x64 程序", flush=True)
        publish = self.work / "windows-publish"
        self.run(["dotnet", "publish", "Windows/HandTodo.Windows.csproj", "-c", "Release", "-r", "win-x64",
                  "--self-contained", "true", "-p:Version=" + self.version, "-o", publish], "windows-build")
        exe = publish / "HandTodo.exe"
        if exe.read_bytes()[:2] != b"MZ":
            raise PackageError("Windows 可执行文件格式错误")
        method = self.args.windows_test
        if method == "auto":
            method = "local" if os.name == "nt" else "github"
        if method == "local":
            if os.name != "nt":
                raise PackageError("Windows 本地原生验证只能在 Windows 上运行")
            report_dir = self.output / "windows-native-test"
            self.run([exe, "--self-test", report_dir], "windows-native-tests")
            result = (report_dir / "result.txt").read_text(encoding="utf-8-sig").strip()
            if not result.startswith("PASS:"):
                raise PackageError("Windows 原生检查未通过")
            verification = {"status": "passed", "method": "native-windows", "result": result}
        elif method == "github":
            verification = verify_windows_github(self.source, self.version, self.output, self.args.wait_seconds)
        else:
            verification = {"status": "not-run", "method": "explicit-skip", "limitation": "Cross-built; no Windows runtime verification"}
        self.manifest["verification"]["windows"] = verification
        target = self.output / ("HandTodo-%s-Windows-x64.zip" % self.version)
        top = "HandTodo-%s-Windows-x64" % self.version
        instructions = (ROOT / "Distribution/使用说明-Windows.txt").read_text().replace("{{VERSION}}", self.version)
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.write(exe, top + "/HandTodo.exe")
            archive.writestr(top + "/使用说明.txt", instructions)
        with zipfile.ZipFile(target) as archive:
            expected = {top + "/HandTodo.exe", top + "/使用说明.txt"}
            if set(archive.namelist()) != expected or archive.testzip() is not None:
                raise PackageError("Windows ZIP 内容或完整性检查失败")
            if hashlib.sha256(archive.read(top + "/HandTodo.exe")).hexdigest() != digest(exe):
                raise PackageError("Windows ZIP 内程序与构建产物不一致")
        verification["executable_sha256"] = digest(exe)
        self.add_artifact("windows", target)

    def write_manifest(self):
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "manifest.json").write_text(json.dumps(self.manifest, ensure_ascii=False, indent=2) + "\n")
        (self.output / "SHA256SUMS.txt").write_text("".join(a["sha256"] + "  " + a["file"] + "\n" for a in self.manifest["artifacts"]))

    def execute(self):
        with release_lock():
            return self._execute_locked()

    def _execute_locked(self):
        self.preflight()
        self.output.mkdir(parents=True)
        self.work.mkdir(parents=True)
        self.manifest["status"] = "building"
        self.write_manifest()
        try:
            for target in self.platforms:
                getattr(self, target)()
                self.write_manifest()
            if source_fingerprint() != self.source["tree_sha256"]:
                raise PackageError("打包过程中源码或素材发生变化，未更新最新产物指针；请重新打包")
            unverified = any(v["status"] != "passed" for v in self.manifest["verification"].values())
            self.manifest["status"] = "completed-unverified" if unverified else "completed"
            self.write_manifest()
            summary = "# HandTodo %s\n\n状态：%s\n\n" % (self.version, self.manifest["status"])
            summary += "\n".join("- [%s](%s) · SHA256 `%s`" % (a["platform"], a["file"], a["sha256"]) for a in self.manifest["artifacts"])
            summary += "\n\n验证详情见 manifest.json。Mac 为临时签名、未公证；Windows 未签名。\n"
            (self.output / "打包记录.md").write_text(summary)
            # A failed run never updates this pointer. Each run has its own immutable directory.
            pointer = ROOT / "Distribution/output/latest.json"
            tmp = pointer.with_suffix(".tmp")
            tmp.write_text(json.dumps({"output": str(self.output), "manifest": str(self.output / "manifest.json"),
                                       "status": self.manifest["status"]}, ensure_ascii=False, indent=2))
            tmp.replace(pointer)
        except (Exception, KeyboardInterrupt) as e:
            self.manifest["status"] = "cancelled" if isinstance(e, KeyboardInterrupt) else "failed"
            self.manifest["error"] = str(e)
            self.write_manifest()
            raise
        print(json.dumps({"status": self.manifest["status"], "output": str(self.output),
                          "artifacts": self.manifest["artifacts"]}, ensure_ascii=False, indent=2), flush=True)
        return self.output

def parser():
    p = argparse.ArgumentParser(description="HandTodo 可复用打包工具：构建、验证、打包和记录，不自动推送或发布")
    p.add_argument("platform", nargs="?", choices=["all", "macos", "windows"], default="all")
    p.add_argument("--version", help="本次打包版本，默认读取项目 VERSION，不修改版本文件")
    p.add_argument("--check", action="store_true", help="仅检查工具和素材，不构建、不联网")
    p.add_argument("--dry-run", action="store_true", help="输出本次计划，不构建、不联网")
    p.add_argument("--windows-test", choices=["auto", "local", "github", "skip"], default="auto",
                   help="默认在 Windows 本机验证，或在 Mac 上使用同一提交的 GitHub Windows 检查；skip 会明确标记未验证")
    p.add_argument("--wait-seconds", type=int, default=900)
    return p

def main(argv=None):
    args = parser().parse_args(argv)
    try:
        pipeline = Pipeline(args)
        if args.check or args.dry_run:
            print(json.dumps(pipeline.preflight(), ensure_ascii=False, indent=2))
        else:
            pipeline.execute()
        return 0
    except KeyboardInterrupt:
        print("打包已取消；此前完成的产物未被覆盖", file=sys.stderr)
        return 130
    except (PackageError, OSError, subprocess.SubprocessError, ValueError) as e:
        print("打包失败：" + str(e), file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
