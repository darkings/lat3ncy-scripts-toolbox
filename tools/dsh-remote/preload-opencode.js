// Preload v3: streaming-aware curl fetch for opencode.ai
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const originalFetch = global.fetch;
function curlFetch(url, init = {}) {
  const urlStr = typeof url === 'string' ? url : url.toString();
  if (!urlStr.includes('opencode.ai')) return originalFetch(url, init);
  const method = (init.method || 'GET').toUpperCase();
  const headers = init.headers || {};
  const body = init.body;
  const signal = init.signal;
  return new Promise((resolve, reject) => {
    const tmpBody = body ? os.tmpdir() + '/curl-' + crypto.randomUUID() + '.tmp' : null;
    if (tmpBody) {
      const bodyBuf = typeof body === 'string' ? Buffer.from(body) : Buffer.isBuffer(body) ? body : Buffer.from(body);
      fs.writeFileSync(tmpBody, bodyBuf);
    }
    const args = ['-s', '-i', '-N', '-X', method, urlStr, '--http1.1', '--max-time', '60'];
    const headerEntries = [];
    if (headers instanceof Headers) {
      for (const [k, v] of headers.entries()) headerEntries.push([k, v]);
    } else if (Array.isArray(headers)) {
      for (const [k, v] of headers) headerEntries.push([k, v]);
    } else if (headers && typeof headers === 'object') {
      for (const [k, v] of Object.entries(headers)) headerEntries.push([k, v]);
    }
    for (const [k, v] of headerEntries) {
      const lk = k.toLowerCase();
      if (['host','content-length','connection','content-encoding'].includes(lk)) continue;
      args.push('-H', `${k}: ${v}`);
    }
    if (tmpBody) args.push('--data-binary', '@' + tmpBody);
    const curl = spawn('curl.exe', args, {windowsHide: true});
    let headerEnded = false;
    let headerBuffer = '';
    let status = 200;
    let statusText = '';
    let responseHeaders = {};
    let streamController = null;
    let response = null;
    let headerParsed = false;
    let pendingChunks = [];
    const stream = new ReadableStream({
      start(controller) { streamController = controller; 
        for(const c of pendingChunks) controller.enqueue(c);
        pendingChunks = [];
      },
      cancel() { try{ curl.kill(); }catch{} }
    });
    if (signal) {
      if (signal.aborted) { try{ curl.kill(); }catch{}; return reject(signal.reason || new Error('aborted')); }
      signal.addEventListener('abort', () => { try{ curl.kill(); }catch{}; if(streamController) try{ streamController.error(signal.reason)}catch{}; reject(signal.reason); });
    }
    curl.stdout.on('data', chunk => {
      if (!headerEnded) {
        headerBuffer += chunk.toString('utf8');
        const idx = headerBuffer.indexOf('\r\n\r\n');
        if (headerBuffer.startsWith('HTTP/1.1 200 Connection established')) {
          const secondStart = headerBuffer.indexOf('HTTP/1.1', 30);
          if (secondStart !== -1) {
            const secondEnd = headerBuffer.indexOf('\r\n\r\n', secondStart);
            if (secondEnd !== -1) {
              const secondHeader = headerBuffer.slice(secondStart, secondEnd);
              const lines = secondHeader.split('\r\n');
              const m = lines[0].match(/HTTP\/\d\.\d (\d+)(.*)/);
              if (m) { status = parseInt(m[1]); statusText = m[2].trim(); }
              for(let i=1;i<lines.length;i++){
                const l=lines[i]; const c=l.indexOf(':'); if(c!==-1) responseHeaders[l.slice(0,c).trim().toLowerCase()] = l.slice(c+1).trim();
              }
              const bodyStart = secondEnd + 4;
              const bodyStr = headerBuffer.slice(bodyStart);
              if (!headerParsed) {
                headerParsed = true;
                response = new Response(stream, {status, statusText, headers: responseHeaders});
                resolve(response);
              }
              if (bodyStr) {
                const buf = Buffer.from(bodyStr, 'utf8');
                if (streamController) streamController.enqueue(buf);
                else pendingChunks.push(buf);
              }
              headerEnded = true;
              return;
            }
          }
        }
        if (idx !== -1 && !headerBuffer.startsWith('HTTP/1.1 200 Connection established')) {
          const headerPart = headerBuffer.slice(0, idx);
          const bodyPart = headerBuffer.slice(idx+4);
          const lines = headerPart.split('\r\n');
          const m = lines[0].match(/HTTP\/\d\.\d (\d+)(.*)/);
          if (m) { status = parseInt(m[1]); statusText = m[2].trim(); }
          for(let i=1;i<lines.length;i++){
            const l=lines[i]; const c=l.indexOf(':'); if(c!==-1) responseHeaders[l.slice(0,c).trim().toLowerCase()] = l.slice(c+1).trim();
          }
          if (!headerParsed) {
            headerParsed = true;
            response = new Response(stream, {status, statusText, headers: responseHeaders});
            resolve(response);
          }
          if (bodyPart) {
            const buf = Buffer.from(bodyPart, 'utf8');
            if (streamController) streamController.enqueue(buf);
            else pendingChunks.push(buf);
          }
          headerEnded = true;
        }
      } else {
        if (streamController) streamController.enqueue(chunk);
        else pendingChunks.push(chunk);
      }
    });
    curl.stderr.on('data', d => {});
    curl.on('close', code => {
      if (tmpBody) try{fs.unlinkSync(tmpBody)}catch{}
      if (!headerParsed) {
        return reject(new Error(`curl exited ${code} without headers`));
      }
      if (streamController) {
        try{ streamController.close(); }catch{}
      }
    });
    curl.on('error', err => {
      if (tmpBody) try{fs.unlinkSync(tmpBody)}catch{}
      reject(err);
    });
  });
}
global.fetch = curlFetch;
globalThis.fetch = curlFetch;
