// Mock backend for the patched JourneyMap webmap frontend.
// Serves webmap-assets/ statically and answers the API routes the Vue app polls,
// so the UI can be exercised in a real browser without Minecraft running.
//
//   node mock-webmap-server.js [port]

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.argv[2] || '8080', 10);
const ROOT = path.join(__dirname, 'webmap-assets');

const TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
};

const PLAYER = {
    posX: 128, posY: 71, posZ: -340,
    biome: 'plains',
};
const WORLD = { dimension: 'minecraft:overworld', name: 'MockWorld' };
const WAYPOINTS = {
    '1': {
        x: 200, y: 70, z: -300, type: 'waypoint', name: 'Home Base',
        enable: true, color: 0xff0000, show: true,
        settings: { enable: true },
        dimensions: ['minecraft:overworld'],
    },
};
const PLAYERS = {
    '2': {
        entityId: '2', username: 'Steve', disabled: false,
        posX: 160, posY: 70, posZ: -300, heading: 90,
        dimension: 'minecraft:overworld',
        serializedTooltips: {},
    },
};

const EMPTY = { ambient: [], animals: [], mobs: [], players: {}, villagers: {} };

function send(res, code, type, body) {
    res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
    res.end(body);
}
function json(res, obj) { send(res, 200, 'application/json', JSON.stringify(obj)); }

const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;

    // ---- API ----
    if (p === '/status') {
        return json(res, {
            status: 'ready',
            mapType: 'day',
            allowedMapTypes: { cave: true, surface: true, topo: true },
        });
    }
    if (p === '/data/all') {
        return json(res, {
            player: PLAYER,
            world: WORLD,
            waypoints: WAYPOINTS,
            messages: [],
            images: { regions: [] },
        });
    }
    if (p === '/data/player') return json(res, PLAYER);
    if (p.startsWith('/data/')) {
        const t = p.slice('/data/'.length);
        if (t === 'players') return json(res, PLAYERS);
        if (t === 'waypoints') return json(res, WAYPOINTS);
        return json(res, EMPTY[t] !== undefined ? EMPTY[t] : {});
    }
    if (p === '/polygons') return json(res, []);
    if (p === '/logs') return send(res, 200, 'text/plain', '(mock log) webmap frontend harness\n');

    if (p === '/tiles/tile.png') {
        // log what the frontend actually asked for - this is the whole point of the patch
        const grid = url.searchParams.get('grid');
        console.log(`[tile] zoom=${url.searchParams.get('zoom')} ` +
                    `x=${url.searchParams.get('x')} z=${url.searchParams.get('z')} grid=${grid}`);

        const png = path.join(ROOT, 'img', 'tile-sample-day.png');
        if (fs.existsSync(png)) {
            const buf = fs.readFileSync(png);
            res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-cache' });
            return res.end(buf);
        }
        return send(res, 404, 'text/plain', 'no tile');
    }

    if (p.startsWith('/skin/') || p.startsWith('/waypoint/')) {
        return send(res, 404, 'text/plain', 'not found');
    }

    // ---- static ----
    const rel = decodeURIComponent(p === '/' ? '/index.html' : p);
    const file = path.join(ROOT, rel);
    if (!file.startsWith(ROOT)) { return send(res, 403, 'text/plain', 'forbidden'); }

    if (fs.existsSync(file) && fs.statSync(file).isFile()) {
        return send(res, 200, TYPES[path.extname(file)] || 'application/octet-stream',
                    fs.readFileSync(file));
    }

    send(res, 404, 'text/plain', 'not found: ' + rel);
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`mock webmap on http://127.0.0.1:${PORT}`);
});