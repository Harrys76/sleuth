/// One part of a fix hint: prose, or a run of code lines.
typedef FixHintPart = ({bool code, String text});

/// Splits [fixHint] into prose and code for the expanded card.
///
/// A code run starts on the line after a prose line ending in `:`, when
/// that line looks like code: it contains `(`, `)`, `{`, `}`, `;` or `=>`,
/// or starts with `flutter `, `dart ` or `//`. The run then also takes
/// indented lines and lines that start with a closing bracket, which
/// carry the arguments of a multi-line call. A bullet (`•`, `- `, `* `)
/// and a sentence (a line ending in `.`) are prose. Prose resumes at the
/// first line that does not match.
/// Blank lines end a run and are dropped.
List<FixHintPart> splitFixHint(String fixHint) {
  final parts = <FixHintPart>[];
  final prose = <String>[];
  final code = <String>[];
  void flushProse() {
    if (prose.isEmpty) return;
    parts.add((code: false, text: prose.join('\n')));
    prose.clear();
  }

  void flushCode() {
    if (code.isEmpty) return;
    parts.add((code: true, text: code.join('\n')));
    code.clear();
  }

  var afterColon = false;
  for (final line in fixHint.split('\n')) {
    final inCode = code.isNotEmpty;
    if (line.trim().isEmpty) {
      flushCode();
      afterColon = false;
      continue;
    }
    if ((inCode && _continuesCode(line)) ||
        ((inCode || afterColon) && _startsCode(line))) {
      if (!inCode) flushProse();
      code.add(line);
      continue;
    }
    flushCode();
    prose.add(line);
    afterColon = line.trimRight().endsWith(':');
  }
  flushCode();
  flushProse();
  return parts;
}

bool _isProse(String trimmed) =>
    trimmed.startsWith('•') ||
    trimmed.startsWith('- ') ||
    trimmed.startsWith('* ') ||
    (trimmed.endsWith('.') && !trimmed.startsWith('//'));

bool _startsCode(String line) {
  final t = line.trim();
  if (_isProse(t)) return false;
  return t.startsWith('flutter ') ||
      t.startsWith('dart ') ||
      t.startsWith('//') ||
      _codeMarks.hasMatch(t);
}

bool _continuesCode(String line) {
  final t = line.trim();
  if (_isProse(t)) return false;
  return _startsCode(line) ||
      line.startsWith(' ') ||
      t.startsWith(')') ||
      t.startsWith(']') ||
      t.startsWith('}');
}

final RegExp _codeMarks = RegExp(r'[(){};]|=>');
