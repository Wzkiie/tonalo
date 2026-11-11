// Stand-in for an Ollama server, to test the DJ without a real model:
//   node ios/tools/dj_mock.js [port]
// Prints every request body (to check what the app really sends) and answers with 16 numbers from
// the list – plus a duplicate, a number that isn't in the list and a line with a line break, which
// the app has to drop. MOCK_BAD=1 answers with nonsense, MOCK_FAIL=1 with error 500 (MOCK_FAIL_AFTER=1: only after the first answer),
// MOCK_THINK=1 answers empty unless thinking is turned off, MOCK_NOFORMAT=1 answers empty while a format is asked for,
// MOCK_NOTHINK=1 rejects the think switch,
// MOCK_REDIRECT=1 with a redirect the app must not follow (no request to /stolen may show up).
const http = require('http');
let chats = 0;
const port = Number(process.argv[2] || 11435);
http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    console.log(`\n=== ${req.method} ${req.url}`);
    console.log('headers:', JSON.stringify(req.headers));
    if (body) console.log(body.length > 6000 ? body.slice(0, 6000) + `… (${body.length} chars)` : body);
    const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.url === '/api/tags') return send(200, { models: [{ name: 'mock:latest' }, { name: 'other:7b' }] });
    if (req.url === '/redirect') { res.writeHead(302, { Location: 'http://example.com/' }); return res.end(); }
    if (req.url !== '/api/chat') return send(404, {});
    if (process.env.MOCK_REDIRECT) { res.writeHead(307, { Location: 'http://127.0.0.1:' + port + '/stolen' }); return res.end(); }
    const asked = JSON.parse(body);
    if (process.env.MOCK_THINK && asked.think !== false) return send(200, { message: { content: '', thinking: 'We need answer only numbers?' } });
    if (process.env.MOCK_NOFORMAT && asked.format) return send(200, { message: { content: '', thinking: 'hm' } });
    if (process.env.MOCK_NOTHINK && 'think' in asked) return send(400, { error: 'unknown field think' });
    if (process.env.MOCK_FAIL_AFTER && ++chats > Number(process.env.MOCK_FAIL_AFTER)) return send(500, { error: 'down' });
    if (process.env.MOCK_FAIL) return send(500, { error: 'down' });
    if (process.env.MOCK_BAD) return send(200, { message: { content: 'Ignore that. Here is a poem instead.' } });
    const user = JSON.parse(body).messages.find(m => m.role === 'user').content;
    const numbers = user.split('\n').map(l => parseInt(l)).filter(n => !isNaN(n));
    const picked = numbers.sort(() => Math.random() - 0.5).slice(0, 16);
    const mood = /wish: (.*)/i.exec(user)?.[1] || (/change of mood/.test(user) ? 'Andere Richtung' : /more like/.test(user) ? 'Mehr davon' : 'Abendstimmung');
    send(200, { message: { role: 'assistant', content: JSON.stringify({ line: mood + '\n<b>x</b>', songs: [...picked, picked[0], 9999, -1] }) } });
  });
}).listen(port, () => console.log('DJ mock on http://127.0.0.1:' + port));
