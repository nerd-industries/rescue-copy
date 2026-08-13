// Cloudflare Pages Function  -  copy.nerdyneighbor.net
// Serves the LATEST committed NN-RescueCopy.ps1 as raw text so that
//   irm copy.nerdyneighbor.net | iex
// always runs the newest version. Fetches via the GitHub Contents API
// (Accept: application/vnd.github.raw) - no CDN staleness. Same design
// as openssh.nerdyneighbor.net.
// Optional: set a GITHUB_TOKEN secret to raise the rate limit to 5,000/hr.

const REPO_API =
  'https://api.github.com/repos/nerd-industries/rescue-copy/contents/NN-RescueCopy.ps1';
const FILE_NAME = 'NN-RescueCopy.ps1';

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const wantDownload =
    url.searchParams.has('download') ||
    url.pathname.replace(/\/+$/, '').toLowerCase().endsWith('/download');
  const accept = context.request.headers.get('Accept') || '';

  if (accept.includes('text/html') && !wantDownload) {
    return new Response(LANDING_HTML, {
      headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
    });
  }

  const headers = {
    'Accept': 'application/vnd.github.raw',
    'User-Agent': 'nerdyneighbor-rescue-copy-proxy',
  };
  if (context.env && context.env.GITHUB_TOKEN) {
    headers['Authorization'] = `Bearer ${context.env.GITHUB_TOKEN}`;
  }

  let upstream;
  try {
    upstream = await fetch(REPO_API, { headers });
  } catch (e) {
    return errorScript(502, `network error reaching GitHub: ${e}`);
  }
  if (!upstream.ok) {
    return errorScript(
      502,
      `GitHub returned ${upstream.status} ${upstream.statusText}` +
        (upstream.status === 403 ? ' (rate limited - set a GITHUB_TOKEN secret)' : '')
    );
  }

  const script = await upstream.text();
  const respHeaders = {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    'x-source': 'github-contents-api',
  };
  if (wantDownload) {
    respHeaders['content-type'] = 'application/octet-stream';
    respHeaders['content-disposition'] = `attachment; filename="${FILE_NAME}"`;
  }
  return new Response(script, { headers: respHeaders });
}

const LANDING_HTML = `<!doctype html><meta charset="utf-8">
<title>Nerdy Neighbor - Rescue Copy</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<body style="font-family:Segoe UI,Arial,sans-serif;max-width:660px;margin:56px auto;padding:0 18px;color:#e2e8f0;background:#0f172a;line-height:1.5">
<h1 style="margin-bottom:4px;color:#38bdf8">NN Rescue Copy</h1>
<p style="color:#94a3b8;margin-top:0">GUI rescue backup for slaved customer drives. Copies OneDrive cloud-reparse files robocopy can't touch. Read-only on the source.</p>

<h3 style="margin-bottom:6px">Run it (full Windows, as Administrator)</h3>
<div style="display:flex;gap:8px;align-items:stretch;flex-wrap:wrap">
  <pre id="cmd" style="flex:1;min-width:280px;background:#1e293b;color:#86efac;padding:14px 16px;border-radius:8px;overflow:auto;margin:0">irm copy.nerdyneighbor.net | iex</pre>
  <button onclick="navigator.clipboard.writeText('irm copy.nerdyneighbor.net | iex').then(()=>{this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',1500)})"
          style="border:0;border-radius:8px;background:#0369a1;color:#fff;font-weight:600;padding:0 18px;cursor:pointer">Copy</button>
</div>

<h3 style="margin-bottom:6px">Or download the script</h3>
<p><a href="?download=1" download="NN-RescueCopy.ps1"
      style="display:inline-block;background:#16a34a;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:8px">Download NN-RescueCopy.ps1</a></p>

<p style="color:#64748b;font-size:12px;margin-top:28px">Nerdy Neighbor recovery toolkit &middot; source: github.com/nerd-industries/rescue-copy</p>
</body>`;

function errorScript(status, reason) {
  const body =
    `Write-Host 'NN Rescue Copy could not be downloaded.' -ForegroundColor Red\n` +
    `Write-Host '${reason.replace(/'/g, "''")}' -ForegroundColor Yellow\n`;
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}
