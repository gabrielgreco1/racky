// node design/motion/tests/parity.js
// Confere lib/motion.js contra as tabelas de progresso a 60 fps de 04 §3.3 e §3.4 (tolerancia 0,015).
global.window = global;
require('../lib/tokens.js');
const M = require('../lib/motion.js');
const f = (n) => n / 60;
const rows = [
  ['standard 200', (n) => M.curve('standard', 0.2, f(n)), { 2: .61, 4: .86, 6: .95, 8: .98, 12: 1 }],
  ['expoOut 300', (n) => M.curve('expoOut', 0.3, f(n)), { 2: .53, 4: .79, 6: .90, 8: .96, 12: .99 }],
  ['exit 150', (n) => M.curve('exit', 0.15, f(n)), { 2: .08, 4: .26, 6: .51, 8: .82, 9: 1 }],
  ['drawer 220', (n) => M.curve('drawer', 0.22, f(n)), { 2: .47, 4: .85, 6: .94, 8: .98, 13: 1 }],
  ['snappy', (n) => M.spring('snappy', f(n)), { 3: .33, 6: .72, 9: .92, 12: .99, 15: 1.004 }],
  ['lively', (n) => M.spring('lively', f(n)), { 6: .55, 12: .97, 18: 1.038, 30: 1.0 }],
  ['cursor', (n) => M.spring('cursor', f(n)), { 6: .59, 12: .94, 21: 1.006 }],
];
let bad = 0;
for (const [name, fn, exp] of rows) {
  const out = Object.entries(exp).map(([n, v]) => {
    const got = fn(+n), ok = Math.abs(got - v) <= 0.015;
    if (!ok) bad++;
    return `f${n} ${got.toFixed(3)}${ok ? '' : ' (esperado ' + v + ')'}`;
  });
  console.log(name.padEnd(14), out.join(' | '));
}
console.log(bad ? `FALHOU: ${bad} amostras fora da tolerancia` : 'OK: paridade com 04 §3.3/§3.4');
process.exit(bad ? 1 : 0);
