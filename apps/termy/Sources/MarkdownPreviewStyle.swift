// MarkdownPreviewStyle.swift
//
// Stylesheet for the markdown preview window. Kept as a Swift string, not a
// bundled .css resource, so `MarkdownHTMLRenderer.document` stays a pure
// function with no bundle lookup. GitHub-like look; light/dark follow the
// window's appearance (termy's appearance setting) via
// `prefers-color-scheme`.

enum MarkdownPreviewStyle {
    static let css = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --code-bg: #f6f8fa; --link: #0969da; --banner-bg: #fff8c5; --banner-border: #d4a72c;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #f0f6fc; --muted: #9198a1; --bg: #0d1117; --border: #3d444d;
        --code-bg: #151b23; --link: #4493f8; --banner-bg: #3a2e05; --banner-border: #9e6a03;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0; color: var(--fg); background: var(--bg);
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    .markdown-body { max-width: 900px; margin: 0 auto; padding: 32px 40px 64px; overflow-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > p { margin: 0; }
    .task-list-item { list-style: none; }
    .task-list-item > input { margin: 0 .35em 0 -1.4em; vertical-align: middle; }
    .task-list-item > input + p { display: inline; }
    blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    code, pre, .raw-html { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 85%; }
    code { padding: .2em .4em; background: var(--code-bg); border-radius: 6px; }
    pre { padding: 16px; overflow: auto; line-height: 1.45; background: var(--code-bg); border-radius: 6px; }
    pre code { padding: 0; background: transparent; font-size: 100%; white-space: pre; }
    table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    th { font-weight: 600; }
    tbody tr:nth-child(2n) td { background: var(--code-bg); }
    hr { height: .25em; margin: 24px 0; background: var(--border); border: 0; }
    del { color: var(--muted); }
    .image-alt { color: var(--muted); font-style: italic; }
    .raw-html { white-space: pre-wrap; color: var(--muted); }
    .preview-banner {
      margin: 0 0 24px; padding: 10px 14px;
      background: var(--banner-bg); border: 1px solid var(--banner-border); border-radius: 6px;
    }
    """
}
