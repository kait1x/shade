import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';

const loopback = '127.0.0.1';
const assets = [
  ['/', 'index.html', 'text/html; charset=utf-8'],
  ['/admin.css', 'admin.css', 'text/css; charset=utf-8'],
  ['/admin.js', 'admin.js', 'text/javascript; charset=utf-8'],
];

export async function createAdminServer(overview) {
  const pages = new Map(await Promise.all(assets.map(async ([route, file, type]) =>
    [route, { type, content: await readFile(new URL('./admin/' + file, import.meta.url)) }])));

  return createServer((req, res) => {
    const host = loopback + ':' + req.socket.localPort;
    const origin = 'http://' + host;
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");

    const send = (status, type, content) => {
      res.writeHead(status, { 'Content-Type': type });
      res.end(req.method === 'HEAD' ? undefined : content);
    };
    if (req.socket.remoteAddress !== loopback || req.headers.host !== host ||
        (req.headers.origin && req.headers.origin !== origin) ||
        req.headers['sec-fetch-site'] === 'cross-site' || !req.url?.startsWith('/')) {
      return send(403, 'text/plain; charset=utf-8', 'Forbidden');
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD');
      return send(405, 'text/plain; charset=utf-8', 'Method not allowed');
    }

    const url = new URL(origin + req.url);
    if (url.pathname === '/overview') {
      const query = (url.searchParams.get('q') || '').slice(0, 32).trim().toLowerCase().replace(/^@/, '');
      const page = Number(url.searchParams.get('page'));
      const onlineOnly = url.searchParams.get('online') === '1';
      const data = overview({ query, page: Number.isSafeInteger(page) && page > 0 ? page : 1, onlineOnly });
      return send(200, 'application/json; charset=utf-8', JSON.stringify(data));
    }

    const asset = pages.get(url.pathname);
    return asset ? send(200, asset.type, asset.content)
      : send(404, 'text/plain; charset=utf-8', 'Not found');
  });
}
