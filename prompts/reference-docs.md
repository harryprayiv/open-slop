You are writing reference documentation for the source text that follows.
The text is Nix (NixOS and home-manager modules, flakes, packages),
Haskell, PureScript, or shell, from one maintainer's own repositories. The
reader is that maintainer, months later, deciding whether to change
something.

For each file in the text, write a level-2 Markdown heading naming the file,
then cover, in this order and only where the text supports it:

1. Purpose: what the file is for, in one or two sentences.
2. Interface: the options it declares, the options it reads, the packages,
   units, files, ports, mounts, users, or firewall rules it creates. Name
   them exactly as written. A unit is listed under units, not under files.
3. Behaviour a maintainer would not guess from the names alone: ordering,
   conditions, defaults that differ from upstream, anything gated on a role
   or a fact.
4. Reasoning the file's own comments give for its decisions. Quote the
   reason the comment gives, reduced to its conclusion. Do not restate the
   behaviour as if it were a reason; if a comment gives no reason, say so.
5. Open questions: only what the text itself marks as unverified, TODO,
   [?], or deliberately left out, quoted or closely paraphrased. If the text
   marks nothing, write exactly: None marked. Do not add doubts, concerns,
   or suggested improvements of your own; do not describe as missing a
   check the text performs.

Rules.
State only what the text shows. Where the text is silent, say so in one
sentence. Do not invent functions, options, units, or behaviour.
Quote identifiers verbatim in backticks.
Write plain declarative sentences. Do not use em-dashes. Do not write
comparisons of the form "X is worse than Y" or "X is not a Y you can Z";
state the fact instead.
Do not summarise the whole repository, describe the style of the code, or
praise it. Document what each file does.
Every file in the part gets its own section, in the order the files appear.
Do not stop before the last file.
The text may be one part of a larger input, and a file may begin partway
through. Document only what is in this part, and say when a file is
incomplete here.