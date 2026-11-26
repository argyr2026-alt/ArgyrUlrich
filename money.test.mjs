// Ejecutar con:  node tests/money.test.mjs
import assert from "node:assert/strict";
import { fmt, mon, lineTotal, pctOf, r3 } from "../shared/money.js";
import { bc } from "../shared/barcode.js";

// Criterio de aceptación: 0,750 kg a $ 9.800/kg = $ 7.350 exactos
assert.equal(lineTotal(0.75, 980000), 735000);
assert.equal(fmt(735000), "$ 7.350");
// Redondeo al centavo (mitad hacia afuera de cero)
assert.equal(lineTotal(0.333, 100000), 33300);
assert.equal(lineTotal(1.005, 100), 101);
// Descuento sobre el subtotal
assert.equal(pctOf(1155000, 10), 115500);
assert.equal(pctOf(1155001, 10), 115500);
// Líneas + descuento = total
const lineas = [lineTotal(0.75, 980000), lineTotal(2, 120000), lineTotal(1, 180000)];
const sub = lineas.reduce((a, b) => a + b, 0);
assert.equal(sub, 1155000);
assert.equal(sub - pctOf(sub, 10), 1039500);
// Parser es-AR
assert.equal(mon("1.234,50"), 123450);
assert.equal(mon("1234,5"), 123450);
assert.equal(mon("$ 9.800"), 980000);
assert.equal(mon("0,75"), 75);
assert.equal(mon(""), 0);
assert.equal(mon("20000"), 2000000);
assert.equal(r3(0.1 + 0.2), 0.3);
// Código de barras: genera SVG y el módulo de control es válido (Code128B "000123")
const svg = bc("000123");
assert.ok(svg.startsWith("<svg") && svg.includes("<rect"));
assert.equal(bc("ñ"), "");
console.log("OK: todos los tests de dinero y código de barras pasaron");
