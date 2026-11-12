"""Syntax check for Lua 5.1 source, with a scope pass.

Parses each file with a recursive-descent parser for the Lua 5.1 grammar and reports the first
syntax error. While parsing it tracks local scopes, so it can also list every name that is used
as a global: assignments to globals (an error in BeamNG's GE Lua) and the globals that are read.

Usage: python luacheck.py file.lua [file.lua ...]
"""
import re
import sys

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}
SYMBOLS = ["...", "..", "==", "~=", "<=", ">=", "+", "-", "*", "/", "%", "^", "#", "<", ">", "=",
           "(", ")", "{", "}", "[", "]", ";", ":", ",", "."]
BINARY = {
    "or": (1, 1), "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
    "..": (5, 4), "+": (6, 6), "-": (6, 6), "*": (7, 7), "/": (7, 7), "%": (7, 7), "^": (10, 9),
}
UNARY_PRIORITY = 8


class LuaError(Exception):
    pass


def tokenize(source):
    tokens = []
    i, line, n = 0, 1, len(source)
    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\r":
            i += 1
        elif source.startswith("--", i):
            m = re.match(r"--\[(=*)\[", source[i:])
            if m:
                close = "]" + m.group(1) + "]"
                end = source.find(close, i)
                if end < 0:
                    raise LuaError(f"line {line}: unfinished long comment")
                line += source.count("\n", i, end)
                i = end + len(close)
            else:
                end = source.find("\n", i)
                i = n if end < 0 else end
        elif c == "[" and re.match(r"\[(=*)\[", source[i:]):
            m = re.match(r"\[(=*)\[", source[i:])
            close = "]" + m.group(1) + "]"
            end = source.find(close, i)
            if end < 0:
                raise LuaError(f"line {line}: unfinished long string")
            tokens.append(("string", source[i:end + len(close)], line))
            line += source.count("\n", i, end)
            i = end + len(close)
        elif c in "\"'":
            j = i + 1
            while True:
                if j >= n or source[j] == "\n":
                    raise LuaError(f"line {line}: unfinished string")
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == c:
                    break
                j += 1
            tokens.append(("string", source[i:j + 1], line))
            i = j + 1
        elif c.isdigit() or (c == "." and i + 1 < n and source[i + 1].isdigit()):
            m = re.match(r"0[xX][0-9a-fA-F]+|\d*\.?\d+(?:[eE][+-]?\d+)?|\d+\.", source[i:])
            tokens.append(("number", m.group(0), line))
            i += len(m.group(0))
        elif c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", source[i:])
            word = m.group(0)
            tokens.append(("keyword" if word in KEYWORDS else "name", word, line))
            i += len(word)
        else:
            for symbol in SYMBOLS:
                if source.startswith(symbol, i):
                    tokens.append(("symbol", symbol, line))
                    i += len(symbol)
                    break
            else:
                raise LuaError(f"line {line}: unexpected character {c!r}")
    tokens.append(("eof", "<eof>", line))
    return tokens


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0
        self.scopes = [set()]
        self.global_reads = {}
        self.global_writes = {}

    # Tokens -------------------------------------------------------------------------------------
    @property
    def tok(self):
        return self.tokens[self.pos]

    def fail(self, message):
        kind, value, line = self.tok
        raise LuaError(f"line {line}: {message} near {value!r}")

    def check(self, value):
        return self.tok[0] in ("keyword", "symbol") and self.tok[1] == value

    def accept(self, value):
        if self.check(value):
            self.pos += 1
            return True
        return False

    def expect(self, value):
        if not self.accept(value):
            self.fail(f"{value!r} expected")

    def name(self):
        if self.tok[0] != "name":
            self.fail("name expected")
        value = self.tok[1]
        self.pos += 1
        return value

    # Scopes -------------------------------------------------------------------------------------
    def declare(self, name):
        self.scopes[-1].add(name)

    def is_local(self, name):
        return any(name in scope for scope in self.scopes)

    def use(self, name, line, write=False):
        if self.is_local(name):
            return
        target = self.global_writes if write else self.global_reads
        target.setdefault(name, line)

    # Statements ---------------------------------------------------------------------------------
    def block(self, new_scope=True, predeclared=()):
        if new_scope:
            self.scopes.append(set(predeclared))
        while True:
            if self.tok[0] == "eof" or self.tok[1] in ("end", "else", "elseif", "until") and self.tok[0] == "keyword":
                break
            if self.check("return"):
                self.pos += 1
                if not (self.tok[0] == "eof" or (self.tok[0] == "keyword" and self.tok[1] in ("end", "else", "elseif", "until")) or self.check(";")):
                    self.explist()
                self.accept(";")
                if not (self.tok[0] == "eof" or (self.tok[0] == "keyword" and self.tok[1] in ("end", "else", "elseif", "until"))):
                    self.fail("'return' must be the last statement of a block")
                break
            if self.check("break"):
                self.pos += 1
                self.accept(";")
                continue
            self.statement()
            self.accept(";")
        if new_scope:
            self.scopes.pop()

    def statement(self):
        if self.accept("do"):
            self.block()
            self.expect("end")
        elif self.accept("while"):
            self.exp()
            self.expect("do")
            self.block()
            self.expect("end")
        elif self.accept("repeat"):
            self.scopes.append(set())
            self.block(new_scope=False)
            self.expect("until")
            self.exp()
            self.scopes.pop()
        elif self.accept("if"):
            self.exp()
            self.expect("then")
            self.block()
            while self.accept("elseif"):
                self.exp()
                self.expect("then")
                self.block()
            if self.accept("else"):
                self.block()
            self.expect("end")
        elif self.accept("for"):
            names = [self.name()]
            if self.accept("="):
                self.exp()
                self.expect(",")
                self.exp()
                if self.accept(","):
                    self.exp()
            else:
                while self.accept(","):
                    names.append(self.name())
                self.expect("in")
                self.explist()
            self.expect("do")
            self.block(predeclared=names)
            self.expect("end")
        elif self.accept("function"):
            line = self.tok[2]
            first = self.name()
            is_method = False
            dotted = False
            while self.accept("."):
                self.name()
                dotted = True
            if self.accept(":"):
                self.name()
                is_method = True
                dotted = True
            self.use(first, line, write=not dotted)
            self.funcbody(is_method)
        elif self.accept("local"):
            if self.accept("function"):
                self.declare(self.name())
                self.funcbody(False)
            else:
                names = [self.name()]
                while self.accept(","):
                    names.append(self.name())
                if self.accept("="):
                    self.explist()
                for name in names:
                    self.declare(name)
        else:
            self.exprstat()

    def exprstat(self):
        start_line = self.tok[2]
        kind, target = self.suffixedexp(assign_target=True)
        if self.check("=") or self.check(","):
            targets = [(kind, target)]
            while self.accept(","):
                targets.append(self.suffixedexp(assign_target=True))
            self.expect("=")
            self.explist()
            for kind, target in targets:
                if kind == "call":
                    raise LuaError(f"line {start_line}: cannot assign to a function call")
                if kind == "name":
                    self.use(target, start_line, write=True)
        else:
            if kind != "call":
                raise LuaError(f"line {start_line}: statement is not a call or an assignment")

    def funcbody(self, is_method):
        self.expect("(")
        params = ["self"] if is_method else []
        if not self.check(")"):
            while True:
                if self.accept("..."):
                    break
                params.append(self.name())
                if not self.accept(","):
                    break
        self.expect(")")
        self.block(predeclared=params)
        self.expect("end")

    # Expressions --------------------------------------------------------------------------------
    def explist(self):
        self.exp()
        while self.accept(","):
            self.exp()

    def exp(self, limit=0):
        if self.tok[0] == "keyword" and self.tok[1] == "not" or self.tok[0] == "symbol" and self.tok[1] in ("-", "#"):
            self.pos += 1
            self.exp(UNARY_PRIORITY)
        else:
            self.simpleexp()
        while self.tok[0] in ("keyword", "symbol") and self.tok[1] in BINARY and BINARY[self.tok[1]][0] > limit:
            operator = self.tok[1]
            self.pos += 1
            self.exp(BINARY[operator][1])

    def simpleexp(self):
        kind, value, _ = self.tok
        if kind in ("number", "string"):
            self.pos += 1
        elif kind == "keyword" and value in ("nil", "true", "false"):
            self.pos += 1
        elif kind == "symbol" and value == "...":
            self.pos += 1
        elif kind == "symbol" and value == "{":
            self.table()
        elif kind == "keyword" and value == "function":
            self.pos += 1
            self.funcbody(False)
        else:
            self.suffixedexp()

    def suffixedexp(self, assign_target=False):
        line = self.tok[2]
        kind, value = None, None
        if self.tok[0] == "name":
            value = self.name()
            kind = "name"
        elif self.accept("("):
            self.exp()
            self.expect(")")
            kind = "paren"
        else:
            self.fail("unexpected symbol")
        root = value if kind == "name" else None
        while True:
            if self.accept("."):
                self.name()
                kind = "index"
            elif self.accept("["):
                self.exp()
                self.expect("]")
                kind = "index"
            elif self.accept(":"):
                self.name()
                self.args()
                kind = "call"
            elif self.check("(") or self.check("{") or self.tok[0] == "string":
                self.args()
                kind = "call"
            else:
                break
        if root is not None and not (assign_target and kind == "name"):
            self.use(root, line)
        return kind, value

    def args(self):
        if self.tok[0] == "string":
            self.pos += 1
        elif self.check("{"):
            self.table()
        else:
            self.expect("(")
            if not self.check(")"):
                self.explist()
            self.expect(")")

    def table(self):
        self.expect("{")
        while not self.check("}"):
            if self.check("["):
                self.pos += 1
                self.exp()
                self.expect("]")
                self.expect("=")
                self.exp()
            elif self.tok[0] == "name" and self.tokens[self.pos + 1][1] == "=" and self.tokens[self.pos + 1][0] == "symbol":
                self.pos += 2
                self.exp()
            else:
                self.exp()
            if not (self.accept(",") or self.accept(";")):
                break
        self.expect("}")


def check_file(path):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    parser = Parser(tokenize(source))
    parser.block(new_scope=False)
    if parser.tok[0] != "eof":
        parser.fail("unexpected token at top level")
    return parser


def main(paths):
    failed = False
    all_reads = {}
    for path in paths:
        try:
            parser = check_file(path)
        except LuaError as error:
            failed = True
            print(f"SYNTAX ERROR  {path}: {error}")
            continue
        print(f"ok  {path}")
        for name, line in sorted(parser.global_writes.items()):
            failed = True
            print(f"   GLOBAL WRITE  {name} (line {line})")
        for name, line in parser.global_reads.items():
            all_reads.setdefault(name, []).append(f"{path.split('/')[-1]}:{line}")
    if all_reads:
        print("\nGlobals read:")
        for name in sorted(all_reads):
            print(f"  {name:36} {', '.join(all_reads[name][:4])}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
