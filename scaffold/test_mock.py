"""lupa 真跑回归：加载 mock 环境 + 插件源码，断言行为。

用法：python scaffold/test_mock.py
退出码 0 = 全通过。
"""
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAFFOLD = ROOT / "scaffold"
PLUGIN = ROOT / "plugins" / "mame_autopress"
TMP_HOME = SCAFFOLD / "_tmp_home"


def static_checks() -> int:
    """静态门禁：BOM / 换行 / JSON 可解析 / 版本三处一致（指南 §1.1、§8.2）。"""
    import json as pyjson

    failed = 0
    pj_path = PLUGIN / "plugin.json"
    init_path = PLUGIN / "init.lua"

    def report(name, ok, msg=""):
        nonlocal failed
        if ok:
            print(f"  PASS  {name}")
        else:
            failed += 1
            print(f"  FAIL  {name}   [{msg}]")

    for p in (pj_path, init_path):
        raw = p.read_bytes()
        report(f"{p.name} 无 BOM", not raw.startswith(b"\xef\xbb\xbf"), f"前 3 字节 {raw[:3].hex()}")
        report(f"{p.name} 全 LF", b"\r" not in raw, "存在 CR")

    pj = None
    try:
        pj = pyjson.loads(pj_path.read_text(encoding="utf-8"))
        report("plugin.json 可解析", True)
    except Exception as exc:  # noqa: BLE001
        report("plugin.json 可解析", False, str(exc))

    if pj:
        pl = pj.get("plugin", {})
        report("plugin.name = mame_autopress", pl.get("name") == "mame_autopress", str(pl.get("name")))
        init_txt = init_path.read_text(encoding="utf-8")
        import re as pyre

        m = pyre.search(r"version\s*=\s*'([0-9.]+)'", init_txt)
        init_ver = m.group(1) if m else "?"
        report("plugin.json 与 init.lua 版本一致",
               pl.get("version") == init_ver, f"{pl.get('version')} vs {init_ver}")
        report("plugin.type = plugin", pl.get("type") == "plugin", str(pl.get("type")))
        report("plugin.start = true", str(pl.get("start")) == "true", str(pl.get("start")))
    return failed


def main() -> int:
    try:
        from lupa import LuaRuntime
    except ImportError:
        print("FAIL: 未安装 lupa，无法真跑 Lua 回归")
        return 2

    # 干净家目录：模拟 <homepath>
    if TMP_HOME.exists():
        shutil.rmtree(TMP_HOME)
    TMP_HOME.mkdir(parents=True)

    print("== 静态门禁 ==")
    static_failed = static_checks()

    print("\n== 行为回归（lupa 真跑）==")
    lua = LuaRuntime(unpack_returned_tuples=True)

    env_src = (SCAFFOLD / "mock_env.lua").read_text(encoding="utf-8")
    cases_src = (SCAFFOLD / "test_mock_cases.lua").read_text(encoding="utf-8")
    init_src = (PLUGIN / "init.lua").read_text(encoding="utf-8")

    lua.execute(env_src)
    mock = lua.globals().MOCK
    mock["homepath"] = str(TMP_HOME)
    # lfs.mkdir 的落盘实现（Lua 侧无法建目录，必须由宿主执行）
    mock["mkdir_hook"] = lambda p: os.makedirs(str(p), exist_ok=True)
    lua.execute(cases_src)

    run_all = lua.globals().RUN_ALL
    import json as pyjson
    pl_ver = pyjson.loads((PLUGIN / "plugin.json").read_text(encoding="utf-8"))["plugin"]["version"]
    results = run_all(init_src, pl_ver)

    n = lua.eval("function(t) return #t end")(results)
    passed = failed = 0
    for i in range(1, n + 1):
        row = results[i]
        name = row["name"]
        ok = bool(row["ok"])
        msg = row["msg"] or ""
        if ok:
            passed += 1
            print(f"  PASS  {name}")
        else:
            failed += 1
            print(f"  FAIL  {name}   [{msg}]")

    print(f"\n合计 {n} 项：通过 {passed}，失败 {failed}（静态 {static_failed} 项失败）")
    if failed or static_failed:
        print("回归失败：请修插件后再部署")
        return 1
    print("回归全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
