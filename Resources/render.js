// render.js: a small Obsidian-flavoured Markdown renderer. No dependencies, runs in the app and in Node.
//
// render(markdown, ctx) -> { html, fm, title }
//
// ctx hooks (all optional, see `defaults`): link(href, innerHtml), wiki(target, innerHtml, heading),
// image(src, alt), embed(name, opts), asset(src) -> url | null.
//
// Supported: frontmatter, headings, paragraphs, bold / italic / strike / highlight, inline code,
// fenced code (light highlighting), lists (nested, tasks), blockquotes, callouts (> [!type]),
// GFM tables, hr, links, wikilinks ([[a|b]], [[a#h]]), images and ![[embeds]], HTML comments,
// a small whitelist of inline tags, and LaTeX math ($x$, $$...$$) when ctx.mathEnabled is true. Math follows
// Pandoc's rule (no space inside the dollars, closing $ not followed by a digit), so `$A$2` and "$5 and $10"
// stay literal, and cell ranges like $F2:$F10 are recognised and left alone.
(function (root) {
  'use strict';

  const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const IMG = /\.(png|jpe?g|gif|svg|webp|avif|bmp)$/i;
  const OPEN = '\u0001', CLOSE = '\u0002';
  const CELL = /^\$?[A-Z]{1,3}\$?\d+\s*[:,]?$/;   // an Excel reference like A2 or $F2:, not LaTeX
  const unangle = (u) => { u = u.trim(); return u[0] === '<' && u[u.length - 1] === '>' ? u.slice(1, -1) : u; };
  const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '');
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

  // ---- code highlighting: classes only, the theme decides how they look ----
  const KW = new Set(('and as assert async await break class continue def del elif else except finally for from global if import in is lambda ' +
    'nonlocal not or pass raise return try while with yield True False None const let var function new this typeof void switch case default do ' +
    'throw catch extends static public private protected interface enum struct func guard defer init self Self nil true false null undefined ' +
    'int float double char long short bool string include print range len').split(/\s+/));
  const HL = new Set(['python', 'py', 'javascript', 'js', 'typescript', 'ts', 'swift', 'c', 'cpp', 'c++', 'java', 'cs', 'sh', 'bash', 'zsh', 'go', 'rust']);
  function highlight(code, lang) {
    if (!HL.has((lang || '').toLowerCase())) return esc(code);
    const re = /(#[^\n]*|\/\/[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_]\w*)\b/g;
    let out = '', last = 0, m;
    while ((m = re.exec(code))) {
      out += esc(code.slice(last, m.index));
      if (m[1]) out += '<span class="c">' + esc(m[1]) + '</span>';
      else if (m[2]) out += '<span class="s">' + esc(m[2]) + '</span>';
      else if (m[3]) out += '<span class="n">' + esc(m[3]) + '</span>';
      else out += KW.has(m[4]) ? '<span class="k">' + esc(m[4]) + '</span>' : esc(m[4]);
      last = re.lastIndex;
    }
    return out + esc(code.slice(last));
  }

  // ---- default hooks ----
  const defaults = {
    link(href, inner) {
      if (/^(https?:|mailto:)/i.test(href)) return '<a href="' + esc(href) + '" data-ext="1">' + inner + '</a>';
      if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return inner; // javascript:, data:, file: and friends are dropped
      if (href[0] === '#') return '<a href="' + esc(href) + '" data-anchor="' + esc(href.slice(1)) + '">' + inner + '</a>';
      return '<a href="#" data-rel="' + esc(href) + '">' + inner + '</a>';
    },
    wiki(target, inner) { return '<a href="#" class="wl" data-wiki="' + esc(target) + '">' + inner + '</a>'; },
    image(src, alt) {
      if (/^https?:/i.test(src)) return '<a href="' + esc(src) + '" data-ext="1">image: ' + esc(alt || src) + '</a>'; // never auto-load remote images
      const url = this.asset(src);
      return url ? '<img src="' + esc(url) + '" alt="' + esc(alt || '') + '" loading="lazy">' : '<span class="missing">[image not found: ' + esc(src) + ']</span>';
    },
    embed(name, opts) { return IMG.test(name) ? this.image(name, '') : this.wiki(name, esc(name)); },
    asset() { return null; },
    mathEnabled: false,
    math(tex, display) { return '<code class="math">' + esc(tex) + '</code>'; }
  };

  // ---- inline ----
  function makeInline(ctx) {
    function run(src, hold) {
      const put = (h) => { hold.push(h); return OPEN + (hold.length - 1) + CLOSE; };
      let s = src;
      // code spans first, so `$A$2` inside backticks is never read as math
      s = s.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, (m, t, c) => put('<code>' + esc(c.replace(/^ (.*) $/, '$1')) + '</code>'));
      if (ctx.mathEnabled) {
        s = s.replace(/\$\$([\s\S]+?)\$\$/g, (m, t) => put(ctx.math(t.trim(), true)));
        s = s.replace(/(?<![\\$])\$(?!\s)((?:[^$\\\n]|\\.)+?)(?<!\s)\$(?!\d)/g,
          (m, t) => (CELL.test(t) ? m : put(ctx.math(t, false))));
      }
      s = s.replace(/\\([\\`*_{}\[\]()#+\-.!|~<>$=^])/g, (m, c) => put(esc(c)));
      s = s.replace(/<(\/?)(small|br|kbd|mark|sub|sup|b|i|u|em|strong|s|del|ins)\s*\/?>/gi,
        (m, sl, tag) => { tag = tag.toLowerCase(); return put(tag === 'br' ? '<br>' : '<' + sl + tag + '>'); });
      s = s.replace(/<(https?:\/\/[^\s>]+)>/g, (m, u) => put(ctx.link(u, esc(u))));
      s = s.replace(/!\[\[([^\]|]+)(?:\|([^\]]*))?\]\]/g, (m, t, o) => put(ctx.embed(t.trim(), o)));
      s = s.replace(/!\[([^\]]*)\]\(\s*(<[^>]+>|(?:[^()\s]|\([^)]*\))+)(?:\s+"[^"]*")?\s*\)/g, (m, alt, u) => put(ctx.image(unangle(u), alt)));
      s = s.replace(/\[\[([^\]|#]+)(?:#([^\]|]*))?(?:\|([^\]]*))?\]\]/g,
        (m, t, h, a) => put(ctx.wiki(t.trim(), run((a || t).trim(), hold), h)));
      s = s.replace(/\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*(<[^>]+>|(?:[^()\s]|\([^)]*\))+)(?:\s+"[^"]*")?\s*\)/g,
        (m, text, u) => put(ctx.link(unangle(u), run(text, hold))));
      s = s.replace(/(^|[\s(>])(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g, (m, pre, u) => pre + put(ctx.link(u, esc(u))));
      s = esc(s);
      return s
        .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, '<strong>$1</strong>')
        .replace(/(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g, '$1<strong>$2</strong>')
        .replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>')
        .replace(/==(?=\S)([\s\S]*?\S)==/g, '<mark>$1</mark>')
        .replace(/\*(?=[^\s*])([\s\S]*?[^\s*])\*/g, '<em>$1</em>')
        .replace(/(^|[^\w])_(?=[^\s_])([\s\S]*?[^\s_])_(?!\w)/g, '$1<em>$2</em>');
    }
    return (src) => {
      const hold = [];
      let s = run(src, hold).replace(/\n/g, '<br>');
      const re = new RegExp(OPEN + '(\\d+)' + CLOSE, 'g');
      for (let guard = 0; guard < 8 && re.test(s); guard++) { re.lastIndex = 0; s = s.replace(re, (m, k) => hold[+k]); }
      return s;
    };
  }

  // ---- blocks ----
  const FENCE = /^\s*(```+|~~~+)\s*([^\s`]*)/;
  const HEAD = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
  const HR = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
  const LI = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
  const QUOTE = /^\s{0,3}>/;
  const SEP = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

  function cells(line) {
    let s = line.trim();
    if (s[0] === '|') s = s.slice(1);
    if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
    const out = []; let cur = '', code = false;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (c === '\\' && s[k + 1] === '|') { cur += '|'; k++; continue; }
      if (c === '`') code = !code;
      if (c === '|' && !code) { out.push(cur.trim()); cur = ''; continue; }
      cur += c;
    }
    out.push(cur.trim());
    return out;
  }
  const width = (ws) => ws.replace(/\t/g, '    ').length;

  function blocks(lines, inline, ctx) {
    const out = [], n = lines.length;
    let i = 0;
    const startsBlock = (k) => {
      const l = lines[k];
      return (ctx.mathEnabled && /^\s*\$\$/.test(l)) || FENCE.test(l) || HEAD.test(l) || HR.test(l) || QUOTE.test(l) || LI.test(l) ||
        (l.includes('|') && k + 1 < n && SEP.test(lines[k + 1]) && cells(l).length > 1 && cells(lines[k + 1]).length === cells(l).length);
    };
    while (i < n) {
      const line = lines[i];
      if (/^\s*$/.test(line)) { i++; continue; }

      if (ctx.mathEnabled && /^\s*\$\$/.test(line)) {
        const start = i;
        let first = line.replace(/^\s*\$\$/, ''), buf = [], closed = false;
        if (/\$\$\s*$/.test(first)) { buf.push(first.replace(/\$\$\s*$/, '')); closed = true; i++; }
        else {
          buf.push(first); i++;
          while (i < n) {
            const l = lines[i++];
            if (/\$\$\s*$/.test(l)) { buf.push(l.replace(/\$\$\s*$/, '')); closed = true; break; }
            buf.push(l);
          }
        }
        if (closed) { out.push('<div class="math-block">' + ctx.math(buf.join('\n').trim(), true) + '</div>'); continue; }
        i = start;   // never closed: treat as ordinary text
      }

      let m = FENCE.exec(line);
      if (m) {
        const mark = m[1][0].repeat(m[1].length), lang = m[2], buf = [];
        i++;
        while (i < n && !new RegExp('^\\s*' + mark + '+\\s*$').test(lines[i])) buf.push(lines[i++]);
        i++;
        out.push('<pre><code' + (lang ? ' data-lang="' + esc(lang) + '"' : '') + '>' + highlight(buf.join('\n'), lang) + '</code></pre>');
        continue;
      }
      if ((m = HEAD.exec(line))) {
        const lvl = m[1].length;
        out.push('<h' + lvl + ' id="' + esc(slug(m[2])) + '">' + inline(m[2]) + '</h' + lvl + '>');
        i++; continue;
      }
      if (HR.test(line)) { out.push('<hr>'); i++; continue; }
      if (QUOTE.test(line)) {
        const q = [];
        while (i < n && QUOTE.test(lines[i])) q.push(lines[i++].replace(/^\s{0,3}>\s?/, ''));
        const co = /^\[!([\w-]+)\]([+-])?[ \t]*(.*)$/.exec(q[0]);
        if (co) {
          const type = co[1].toLowerCase(), title = co[3] ? inline(co[3]) : esc(cap(type));
          const body = blocks(q.slice(1), inline, ctx);
          const inner = '<div class="co-t" data-type="' + esc(type) + '">' + title + '</div>' + (body ? '<div class="co-b">' + body + '</div>' : '');
          out.push(co[2] ? '<details class="callout" data-type="' + esc(type) + '"' + (co[2] === '+' ? ' open' : '') + '><summary class="co-t" data-type="' + esc(type) + '">' + title + '</summary>' + (body ? '<div class="co-b">' + body + '</div>' : '') + '</details>'
            : '<div class="callout" data-type="' + esc(type) + '">' + inner + '</div>');
        } else out.push('<blockquote>' + blocks(q, inline, ctx) + '</blockquote>');
        continue;
      }
      if (line.includes('|') && i + 1 < n && SEP.test(lines[i + 1]) && cells(line).length > 1 && cells(lines[i + 1]).length === cells(line).length) {
        const head = cells(line), al = cells(lines[i + 1]).map((c) => (/^:-+:$/.test(c) ? 'center' : /-+:$/.test(c) ? 'right' : /^:-+/.test(c) ? 'left' : ''));
        i += 2;
        const rows = [];
        while (i < n && lines[i].includes('|') && !/^\s*$/.test(lines[i])) rows.push(cells(lines[i++]));
        const td = (tag, c, k) => '<' + tag + (al[k] ? ' style="text-align:' + al[k] + '"' : '') + '>' + inline(c || '') + '</' + tag + '>';
        out.push('<div class="tw"><table><thead><tr>' + head.map((c, k) => td('th', c, k)).join('') + '</tr></thead><tbody>' +
          rows.map((r) => '<tr>' + head.map((_, k) => td('td', r[k], k)).join('') + '</tr>').join('') + '</tbody></table></div>');
        continue;
      }
      if (LI.test(line)) {
        const items = [];
        while (i < n) {
          if (/^\s*$/.test(lines[i])) {
            let k = i; while (k < n && /^\s*$/.test(lines[k])) k++;
            if (k < n && (LI.test(lines[k]) || /^\s{2,}\S/.test(lines[k])) && items.length) { i = k; continue; }
            break;
          }
          const li = LI.exec(lines[i]);
          if (li) { items.push({ indent: width(li[1]), ord: /\d/.test(li[2]), text: li[3] }); i++; continue; }
          if (/^\s{2,}\S/.test(lines[i]) && items.length) { items[items.length - 1].text += '\n' + lines[i].trim(); i++; continue; }
          break;
        }
        const stack = []; let html = '';
        const open = (it) => { const tag = it.ord ? 'ol' : 'ul'; html += '<' + tag + '>'; stack.push({ indent: it.indent, tag }); };
        for (const it of items) {
          if (!stack.length) open(it);
          else {
            while (stack.length > 1 && it.indent < stack[stack.length - 1].indent) html += '</li></' + stack.pop().tag + '>';
            if (it.indent > stack[stack.length - 1].indent) open(it); else html += '</li>';
          }
          const task = /^\[([ xX])\]\s+/.exec(it.text);
          html += '<li' + (task ? ' class="task"' : '') + '>' + (task ? '<span class="box">' + (task[1] === ' ' ? '[ ]' : '[x]') + '</span> ' : '') + inline(task ? it.text.slice(task[0].length) : it.text);
        }
        while (stack.length) html += '</li></' + stack.pop().tag + '>';
        out.push(html);
        continue;
      }
      const para = [line];
      i++;
      while (i < n && !/^\s*$/.test(lines[i]) && !startsBlock(i)) para.push(lines[i++]);
      out.push('<p>' + inline(para.map((l) => l.trim()).join('\n')) + '</p>');
    }
    return out.join('\n');
  }

  function frontmatter(text) {
    const m = /^---[ \t]*\n([\s\S]*?)\n---[ \t]*(\n|$)/.exec(text);
    if (!m) return { fm: {}, body: text };
    const fm = {}, strip = (v) => v.replace(/^(["'])(.*)\1$/, '$2');
    let key = null;
    for (const line of m[1].split('\n')) {
      let k;
      if ((k = /^([\w-]+):[ \t]*(.*)$/.exec(line))) { key = k[1]; const v = k[2].trim(); fm[key] = v === '' ? [] : strip(v); }
      else if ((k = /^\s*-\s+(.*)$/.exec(line)) && key) { if (!Array.isArray(fm[key])) fm[key] = []; fm[key].push(strip(k[1].trim())); }
    }
    return { fm, body: text.slice(m[0].length) };
  }

  function render(md, userCtx) {
    const ctx = Object.assign({}, defaults, userCtx || {});
    const inline = makeInline(ctx);
    const { fm, body } = frontmatter(String(md).replace(/\r\n?/g, '\n'));
    const text = body.replace(/<!--[\s\S]*?-->/g, '');
    const t = /^#\s+(.+)$/m.exec(text);
    return { html: blocks(text.split('\n'), inline, ctx), fm, title: fm.title || (t ? t[1].replace(/[*_`]/g, '').trim() : '') };
  }

  // Obsidian (MathJax) is lenient where KaTeX is strict: a bare # in \text{}, or stray $ inside the dollars.
  const cleanTex = (tex) => tex.replace(/^\s*\$+\s*|\s*\$+\s*$/g, '').replace(/(?<!\\)#/g, '\\#');

  const api = { render, frontmatter, esc, cleanTex };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.VaultMD = api;
})(typeof window !== 'undefined' ? window : globalThis);
