// Dinero siempre en CENTAVOS ENTEROS. Cantidades con hasta 3 decimales (kg).
export const fmt = c => "$ " + (c / 100).toLocaleString("es-AR", { minimumFractionDigits: c % 100 ? 2 : 0, maximumFractionDigits: 2 });
export const fmt2 = c => "$ " + (c / 100).toLocaleString("es-AR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const kg = q => q.toLocaleString("es-AR", { minimumFractionDigits: 3, maximumFractionDigits: 3 });
export const nq = q => q.toLocaleString("es-AR", { maximumFractionDigits: 3 });
// Parser tolerante: "1.234,50", "1234,5", "$ 9.800", "0,75" -> centavos
export const mon = s => {
  s = String(s).replace(/[^\d.,]/g, "");
  if (!s) return 0;
  if (s.includes(",")) s = s.replace(/\./g, "").replace(",", ".");
  else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, "");
  return Math.round(parseFloat(s) * 100) || 0;
};
export const dec = s => parseFloat(String(s).replace(",", ".")) || 0;
export const r3 = x => Math.round(x * 1000) / 1000;
// total de línea = round(cantidad × precio_unitario_en_centavos)
export const lineTotal = (q, precio) => Math.round(+(q * precio).toFixed(6));
// descuento = round(subtotal × pct / 100)
export const pctOf = (subtotal, pct) => Math.round(subtotal * pct / 100);
export const norm = s => String(s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
