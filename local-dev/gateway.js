#!/usr/bin/env node
'use strict';

/*
 * Local development gateway for the Authoring UI.
 *
 * Stands in for the nginx + IMS front door of a real Authoring Platform deployment:
 *   - a trivial login page that lets you pick a local user (no passwords)
 *   - a fake IMS: /auth for the UI and /ims/* for Authoring Services
 *   - injects the X-AUTH-username / X-AUTH-roles / X-AUTH-token headers that
 *     Authoring Services and Snowstorm trust, based on the login cookie
 *   - proxies /authoring-services/ and /snowstorm/snomed-ct/ to the local backends
 *     (including the SockJS websocket) and everything else to `grunt serve`
 *
 * For local use only. Zero dependencies, Node 18+.
 */

var http = require('http');
var fs = require('fs');
var path = require('path');
var url = require('url');

var PORT = parseInt(process.env.GATEWAY_PORT || '9100', 10);
var UI_URL = process.env.UI_URL || 'http://localhost:9001';
var AS_URL = process.env.AS_URL || 'http://localhost:8081';
var SNOWSTORM_URL = process.env.SNOWSTORM_URL || 'http://localhost:8090';
var USERS_FILE = process.env.USERS_FILE || path.join(__dirname, 'users.json');

var COOKIE_NAME = 'local-ims';
var SNOWSTORM_PREFIX = '/snowstorm/snomed-ct';

// Backends the UI may call that are not part of the local stack
var UNAVAILABLE_PREFIXES = [
  '/authoring-acceptance-gateway/',
  '/rvf/',
  '/release-notes/',
  '/release-notes-management/',
  '/reporting/',
  '/authoring-traceability-service/',
  '/template-service/',
  '/validation-reports/',
  '/validation-browser/'
];

function loadUsers() {
  var users = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
  return users.map(function (u) {
    var displayName = u.firstName + ' ' + u.lastName;
    return {
      login: u.login,
      username: u.login,
      firstName: u.firstName,
      lastName: u.lastName,
      displayName: displayName,
      email: u.email || (u.login + '@localhost'),
      roles: u.roles,
      active: true,
      langKey: 'en'
    };
  });
}

function findUser(login) {
  return loadUsers().filter(function (u) {
    return u.login === login;
  })[0];
}

function parseCookies(req) {
  var cookies = {};
  (req.headers.cookie || '').split(';').forEach(function (part) {
    var idx = part.indexOf('=');
    if (idx > 0) {
      cookies[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
    }
  });
  return cookies;
}

function currentUser(req) {
  var login = parseCookies(req)[COOKIE_NAME];
  return login ? findUser(login) : null;
}

function sendJson(res, status, body) {
  res.writeHead(status, {'Content-Type': 'application/json'});
  res.end(JSON.stringify(body));
}

function redirect(res, location, extraHeaders) {
  var headers = {Location: location};
  Object.keys(extraHeaders || {}).forEach(function (k) {
    headers[k] = extraHeaders[k];
  });
  res.writeHead(302, headers);
  res.end();
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', '\'': '&#39;'}[c];
  });
}

function loginPage(res, user) {
  var rows = loadUsers().map(function (u) {
    var roles = u.roles.map(function (r) { return r.replace(/^ROLE_/, ''); }).join(', ');
    return '<li><a href="/local-login?user=' + encodeURIComponent(u.login) + '">' + escapeHtml(u.login) +
      '</a> &mdash; ' + escapeHtml(u.displayName) + ' <small>(' + escapeHtml(roles) + ')</small></li>';
  }).join('\n');
  var current = user ? '<p>Currently logged in as <b>' + escapeHtml(user.login) + '</b>. <a href="/">Continue</a> &middot; <a href="/ims/logout">Log out</a></p>' : '';
  res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
  res.end('<!doctype html><html><head><meta charset="utf-8"><title>Local login</title>' +
    '<style>body{font-family:-apple-system,sans-serif;max-width:40em;margin:3em auto;padding:0 1em}li{margin:.5em 0}</style></head>' +
    '<body><h1>Authoring UI &mdash; local login</h1>' + current +
    '<p>Choose a user (edit <code>local-dev/users.json</code> to add more):</p><ul>' + rows + '</ul></body></html>');
}

// Fake IMS endpoints used by Authoring Services (ims.url=http://localhost:PORT/ims)
// and by the UI's login / logout / settings links (imsEndpoint=/ims/)
function handleIms(req, res, pathname, query) {
  var user = currentUser(req);
  switch (pathname) {
    case '/ims/account':
      return user ? sendJson(res, 200, user) : sendJson(res, 401, {error: 'Not logged in'});
    case '/ims/user':
      var found = findUser(query.username);
      return found ? sendJson(res, 200, found) : sendJson(res, 404, {error: 'User not found'});
    case '/ims/group/user':
      var group = 'ROLE_' + String(query.groupname || '').replace(/^ROLE_/, '');
      return sendJson(res, 200, loadUsers().filter(function (u) {
        return u.roles.indexOf(group) !== -1;
      }));
    case '/ims/login':
      return redirect(res, '/local-login');
    case '/ims/logout':
      return redirect(res, '/local-login', {'Set-Cookie': COOKIE_NAME + '=; Path=/; Max-Age=0'});
    default:
      return redirect(res, '/');
  }
}

function authHeaders(req) {
  var user = currentUser(req);
  if (!user) {
    return {};
  }
  return {
    'x-auth-username': user.login,
    'x-auth-roles': user.roles.join(','),
    // Authoring Services forwards this value as the Cookie header when it calls
    // Snowstorm and IMS (through this gateway), which maps it back to the user
    'x-auth-token': COOKIE_NAME + '=' + encodeURIComponent(user.login)
  };
}

function backendFor(pathname) {
  if (pathname === '/authoring-services' || pathname.indexOf('/authoring-services/') === 0) {
    return {target: AS_URL, path: null, auth: true};
  }
  if (pathname === SNOWSTORM_PREFIX || pathname.indexOf(SNOWSTORM_PREFIX + '/') === 0) {
    return {target: SNOWSTORM_URL, path: pathname.slice(SNOWSTORM_PREFIX.length) || '/', auth: true};
  }
  return {target: UI_URL, path: null, auth: false};
}

function buildHeaders(req, backend, targetHost) {
  var headers = {};
  Object.keys(req.headers).forEach(function (k) {
    // never trust identity headers sent by the browser
    if (k.toLowerCase().indexOf('x-auth-') !== 0) {
      headers[k] = req.headers[k];
    }
  });
  headers.host = targetHost;
  headers['x-forwarded-host'] = req.headers.host;
  headers['x-forwarded-proto'] = 'http';
  if (backend.auth) {
    var extra = authHeaders(req);
    Object.keys(extra).forEach(function (k) {
      headers[k] = extra[k];
    });
  }
  return headers;
}

function proxy(req, res, parsed) {
  var backend = backendFor(parsed.pathname);
  var target = url.parse(backend.target);
  var targetPath = backend.path !== null ? backend.path + (parsed.search || '') : req.url;
  var upstream = http.request({
    hostname: target.hostname,
    port: target.port,
    method: req.method,
    path: targetPath,
    headers: buildHeaders(req, backend, target.host)
  }, function (upstreamRes) {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.pipe(res);
  });
  upstream.on('error', function (err) {
    if (!res.headersSent) {
      sendJson(res, 502, {error: 'Bad gateway', target: backend.target, message: err.message});
    } else {
      res.end();
    }
  });
  req.pipe(upstream);
}

function handleRequest(req, res) {
  var parsed = url.parse(req.url, true);
  var pathname = parsed.pathname;

  if (pathname === '/local-login') {
    if (parsed.query.user && findUser(parsed.query.user)) {
      return redirect(res, '/', {'Set-Cookie': COOKIE_NAME + '=' + encodeURIComponent(parsed.query.user) + '; Path=/; HttpOnly; SameSite=Lax'});
    }
    return loginPage(res, currentUser(req));
  }
  if (pathname === '/auth') {
    var user = currentUser(req);
    return user ? sendJson(res, 200, user) : sendJson(res, 401, {error: 'Not logged in'});
  }
  if (pathname === '/ims' || pathname.indexOf('/ims/') === 0) {
    return handleIms(req, res, pathname, parsed.query);
  }
  if (pathname === '/config/versions.json') {
    return sendJson(res, 200, {versions: {}});
  }
  if (pathname === '/launcherConfig.json') {
    return sendJson(res, 200, {apps: []});
  }
  if (pathname === '/' && !currentUser(req)) {
    return redirect(res, '/local-login');
  }
  for (var i = 0; i < UNAVAILABLE_PREFIXES.length; i++) {
    if (pathname.indexOf(UNAVAILABLE_PREFIXES[i]) === 0) {
      return sendJson(res, 503, {error: 'Service not available in the local stack', path: pathname});
    }
  }
  proxy(req, res, parsed);
}

// WebSocket upgrades (SockJS for Authoring Services notifications)
function handleUpgrade(req, socket, head) {
  var parsed = url.parse(req.url, true);
  var backend = backendFor(parsed.pathname);
  var target = url.parse(backend.target);
  var targetPath = backend.path !== null ? backend.path + (parsed.search || '') : req.url;
  var upstream = http.request({
    hostname: target.hostname,
    port: target.port,
    method: req.method,
    path: targetPath,
    headers: buildHeaders(req, backend, target.host)
  });
  upstream.on('upgrade', function (upstreamRes, upstreamSocket, upstreamHead) {
    var lines = ['HTTP/1.1 101 Switching Protocols'];
    Object.keys(upstreamRes.headers).forEach(function (k) {
      lines.push(k + ': ' + upstreamRes.headers[k]);
    });
    socket.write(lines.join('\r\n') + '\r\n\r\n');
    if (upstreamHead && upstreamHead.length) {
      socket.write(upstreamHead);
    }
    if (head && head.length) {
      upstreamSocket.write(head);
    }
    upstreamSocket.pipe(socket).pipe(upstreamSocket);
  });
  upstream.on('response', function (upstreamRes) {
    socket.end('HTTP/1.1 ' + upstreamRes.statusCode + ' ' + upstreamRes.statusMessage + '\r\n\r\n');
  });
  upstream.on('error', function () {
    socket.destroy();
  });
  upstream.end();
}

// Listen on both loopback addresses: browsers may use either for "localhost",
// while Java (Authoring Services) uses 127.0.0.1
['127.0.0.1', '::1'].forEach(function (address) {
  var server = http.createServer(handleRequest);
  server.on('upgrade', handleUpgrade);
  server.on('error', function (err) {
    console.error('Could not listen on ' + address + ':' + PORT + ' - ' + err.message);
  });
  server.listen(PORT, address);
});

console.log('Local gateway listening on http://localhost:' + PORT);
console.log('  UI                  -> ' + UI_URL);
console.log('  /authoring-services -> ' + AS_URL);
console.log('  ' + SNOWSTORM_PREFIX + ' -> ' + SNOWSTORM_URL);
