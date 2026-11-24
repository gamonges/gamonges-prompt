"""review-adr の入力が、Phase 1 の作り直しで消える場所にあるかを判定する。

使い方:
  python3 input_guard.py <入力のパス> <対象 repo>

Phase 1 は `rm -rf <対象 repo>/tmp/adr-review` で出力先を作り直す。入力がその下に
あると、レビューを始める前に入力の ADR を消す。

- 入力は起動時の cwd で解決してから realpath にする
- 出力先の側も `realpath(<対象 repo>/tmp)` + `adr-review` にする。tmp が repo の外を
  指す symlink だと、rm -rf はその実体をたどって消すため（入力だけを realpath すると、
  実体パスが出力先の外に見えて通ってしまう）
- 包含はパスの要素単位で比べる（文字列の前方一致だと tmp/adr-review-old を含めてしまう）
- 出力先が在れば、入力の祖先を samefile でも比べる（大文字小文字を区別しないボリュームでは
  TMP/ADR-REVIEW も同じ場所で、文字列の比較では一致しないのに rm -rf が消すため）

終了コード: 0 = 消えない場所 / 1 = 消える場所（止まる）/ 2 = 引数の誤り・入力が無い
"""
import os
import sys

PROG = "input_guard.py"


def under_same(path, out):
    """path の祖先のどれかが out と同じ実体か（out が無ければ False）"""
    if not os.path.isdir(out):
        return False
    d = os.path.dirname(path)
    while True:
        try:
            if os.path.samefile(d, out):
                return True
        except OSError:
            pass
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(PROG + ": 使い方: " + PROG + " <入力のパス> <対象 repo>\n")
        return 2
    src, repo = argv[1], argv[2]
    if not os.path.isfile(src):
        sys.stderr.write(PROG + ": 入力が無い: " + src + "\n")
        return 2
    real_src = os.path.realpath(os.path.abspath(src))
    # tmp が無ければ realpath はそのままのパスを返し、存在する入力がその下に来ることは無い
    out = os.path.join(os.path.realpath(os.path.join(repo, "tmp")), "adr-review")
    if os.path.commonpath([real_src, out]) == out or under_same(real_src, out):
        sys.stderr.write(PROG + ": 入力が出力の作り直しで消える場所（tmp/adr-review/）にある: "
                         + real_src + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
