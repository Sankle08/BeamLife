"""Static checks for Vue single-file components.

For each .vue file: the template's tags must be balanced, every name used in the template must be
declared in <script setup> (import, const, function, or a destructured name), and the script must
pass `node --check`. For each .js file: `node --check`.

Usage: python vuecheck.py <folder> <scratch folder>
"""
import os
import re
import subprocess
import sys
from html.parser import HTMLParser

VOID = {"br", "img", "input", "hr", "meta", "link"}
JS_WORDS = {
    "true", "false", "null", "undefined", "Math", "Number", "String", "Object", "Array", "JSON", "in", "of",
    "typeof", "new", "item", "index", "$emit", "$event", "event", "isNaN", "Boolean", "Date",
}


class TagBalance(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.stack = []
        self.problems = []
        self.attributes = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        self.attributes.extend(attrs)
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))

    def handle_startendtag(self, tag, attrs):
        self.attributes.extend(attrs)

    def handle_endtag(self, tag):
        if not self.stack:
            self.problems.append(f"line {self.getpos()[0]}: closing </{tag}> with nothing open")
            return
        open_tag, line = self.stack.pop()
        if open_tag != tag:
            self.problems.append(f"line {self.getpos()[0]}: </{tag}> closes <{open_tag}> opened on line {line}")

    def handle_data(self, data):
        self.text.append(data)


def section(source, name):
    match = re.search(rf"<{name}\b[^>]*>(.*)</{name}>", source, re.S)
    return match.group(1) if match else None


def declared_names(script):
    names = set()
    for match in re.finditer(r"import\s+(\w+)\s+from", script):
        names.add(match.group(1))
    for match in re.finditer(r"import\s*\{([^}]*)\}", script):
        names.update(part.strip().split(" as ")[-1].strip() for part in match.group(1).split(",") if part.strip())
    for match in re.finditer(r"(?:const|let)\s+\{([^}]*)\}\s*=", script):
        names.update(part.strip().split(":")[-1].strip() for part in match.group(1).split(",") if part.strip())
    for match in re.finditer(r"(?:const|let)\s+(\w+)\s*=", script):
        names.add(match.group(1))
    for match in re.finditer(r"(?:async\s+)?function\s+(\w+)", script):
        names.add(match.group(1))
    props = re.search(r"defineProps\(\{(.*?)\n\}\)", script, re.S) or re.search(r"defineProps\(\{(.*?)\}\)", script, re.S)
    if props:
        names.update(re.findall(r"(\w+)\s*:\s*\{", props.group(1)))
    return names


def template_names(parser):
    """Root identifiers of the expressions in the template, with v-for locals removed."""
    expressions, loop_locals = [], set()
    for key, value in parser.attributes:
        if value is None:
            continue
        if key == "v-for":
            left, _, right = value.partition(" in ")
            loop_locals.update(re.findall(r"\w+", left))
            expressions.append(right)
        elif key.startswith((":", "@", "v-")):
            expressions.append(value)
    for chunk in parser.text:
        expressions.extend(re.findall(r"\{\{(.*?)\}\}", chunk, re.S))
    used = set()
    for expression in expressions:
        cleaned = re.sub(r"'[^']*'|\"[^\"]*\"", " ", expression)
        cleaned = re.sub(r"`[^`]*`", lambda m: " ".join(re.findall(r"\$\{([^}]*)\}", m.group(0))), cleaned)
        cleaned = re.sub(r"'[^']*'|\"[^\"]*\"", " ", cleaned)
        # Arrow-function parameters are local to the expression.
        arrow_locals = set(re.findall(r"(\w+)\s*=>", cleaned))
        for match in re.finditer(r"(?<![\w.$?])([A-Za-z_$][\w$]*)", cleaned):
            word = match.group(1)
            following = cleaned[match.end():].lstrip()
            # An object-literal key is not a reference ("on: job.payMode === 'daily'").
            is_key = following.startswith(":") and not following.startswith("::") and re.search(r"[{,]\s*$", cleaned[:match.start()])
            if not is_key and word not in arrow_locals:
                used.add(word)
    return used - loop_locals - JS_WORDS


def check_vue(path, scratch):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    problems = []
    template, script = section(source, "template"), section(source, "script")
    if template is None:
        return ["no <template>"]
    parser = TagBalance()
    parser.feed(template)
    problems.extend(parser.problems)
    for tag, line in parser.stack:
        problems.append(f"<{tag}> opened on template line {line} is never closed")
    script = script or ""
    unknown = template_names(parser) - declared_names(script)
    if unknown:
        problems.append("template uses undeclared names: " + ", ".join(sorted(unknown)))
    if script.strip():
        target = os.path.join(scratch, os.path.basename(path) + ".mjs")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(script)
        result = subprocess.run(["node", "--check", target], capture_output=True, text=True)
        if result.returncode != 0:
            problems.append("script: " + result.stderr.strip().splitlines()[-1] + " | " + " ".join(result.stderr.split()[:12]))
    return problems


def check_js(path, scratch):
    target = os.path.join(scratch, os.path.basename(path) + ".mjs")
    with open(path, encoding="utf-8") as source, open(target, "w", encoding="utf-8") as handle:
        handle.write(source.read())
    result = subprocess.run(["node", "--check", target], capture_output=True, text=True)
    return [] if result.returncode == 0 else [" ".join(result.stderr.split()[:20])]


def main(folder, scratch):
    os.makedirs(scratch, exist_ok=True)
    failed = False
    for directory, _, files in os.walk(folder):
        for name in sorted(files):
            path = os.path.join(directory, name)
            if name.endswith(".vue"):
                problems = check_vue(path, scratch)
            elif name.endswith(".js"):
                problems = check_js(path, scratch)
            else:
                continue
            print(("FAIL  " if problems else "ok    ") + os.path.relpath(path, folder))
            for problem in problems:
                failed = True
                print("        " + problem)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
