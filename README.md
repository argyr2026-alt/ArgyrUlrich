# ARGYR · Caja + Gestión (Fase 1)

App web para kiosco / carnicería / verdulería: caja, productos con código de barras, stock, clientes con fiado, gastos, retiros, turnos con arqueo y estadísticas. Sin paso de build: HTML + JavaScript (módulos) + Supabase.

> **Estado honesto:** el código se probó con un Supabase *simulado* (que las pantallas rendericen y que cada acción llame a la función correcta) y los cálculos de dinero tienen tests. **El SQL todavía no se ejecutó contra una base real.** Hacé la prueba completa en un proyecto de *prueba* antes de usarlo con datos reales (ver sección 5).

## Estructura

```
index.html  app.js  config.js  vercel.json
shared/     money.js (dinero en centavos) · barcode.js (Code 128)
supabase/   schema.sql · functions.sql · policies.sql
tests/      money.test.mjs      →  node tests/money.test.mjs
docs/       GUIA_DE_USO.md
```

## 1. GitHub

1. Creá cuenta en github.com y activá la verificación en dos pasos.
2. **New repository** → nombre `argyr-caja-gestion` → **Private**.
3. **Add file → Upload files**: subí *todo el contenido* de esta carpeta (respetando las subcarpetas). Si usás Git: `git init`, `git add .`, `git commit -m "Fase 1"`, `git remote add origin <url>`, `git push -u origin main`.
4. En `config.js` solo van la URL y la clave **pública** de Supabase. **Nunca** subas la clave `service_role`.

## 2. Supabase (primero un proyecto de PRUEBA)

1. supabase.com → **New project** (nombre, contraseña de base fuerte guardada en un gestor, región São Paulo).
2. **SQL Editor → New query**. Pegá y ejecutá **uno por vez y en este orden**:
   1. `supabase/schema.sql`
   2. `supabase/functions.sql`
   3. `supabase/policies.sql`
   Si alguno da error, copiá el mensaje completo (con el número de línea) y pasámelo.
3. **Authentication → Users → Add user**: tu email y contraseña (tildá *Auto confirm*).
4. **Authentication → Sign In / Providers**: desactivá el registro libre (*Allow new users to sign up*), para que nadie más pueda crearse cuenta.
5. **Project Settings → API**: copiá **Project URL** y la clave pública (`anon` o `publishable`) y pegalas en `config.js`.
6. Al entrar por primera vez la app te ofrece **“Crear mi negocio”** (arma caja, lista “Mostrador” y las categorías Verdulería, Carnicería y Kiosco). En Productos podés **cargar productos de ejemplo**.

## 3. Vercel

1. vercel.com → entrá con GitHub → **Add New → Project** → elegí el repo.
2. Framework: **Other**. Sin comando de build ni carpeta de salida (déjalos vacíos). **Deploy**.
3. Te da una dirección `https://….vercel.app`. Cada cambio que subas a GitHub se republica solo.
4. Dominio propio: **Settings → Domains**.
5. En Supabase → **Authentication → URL Configuration**, poné esa dirección en *Site URL*.
6. **Plan:** el plan gratuito *Hobby* de Vercel es para uso personal no comercial; para un negocio corresponde un plan de pago. Confirmá precios y condiciones vigentes en vercel.com/pricing.

## 4. Pasar a producción

1. Probá todo (sección 5) en el proyecto de prueba.
2. Creá un **segundo proyecto Supabase** para producción y repetí la sección 2. Cambiá `config.js` a las claves de producción.
3. Elegí un plan de Supabase adecuado para negocio (el gratuito pausa proyectos con poca actividad y no es ideal; revisá backups diarios en la página de facturación).
4. Cargá productos y stock reales y trabajá una semana en paralelo con tu método actual.

## 5. Checklist de prueba manual (marcá cada una)

- [ ] Ingresar con tu usuario; “Crear mi negocio”; cargar productos de ejemplo.
- [ ] Abrir turno con $ 20.000.
- [ ] Vender 0,750 kg de milanesa a $ 9.800/kg → total **$ 7.350** y el stock baja 0,750.
- [ ] Pagar $ 20.000 en efectivo → vuelto correcto. Pago mixto efectivo + transferencia. Fiado a un cliente.
- [ ] Fiado que supera el límite del cliente → se rechaza.
- [ ] Imprimir ticket (se abre la vista previa y el botón Imprimir).
- [ ] Anular una venta del turno → vuelve el stock; si fue fiado baja la deuda.
- [ ] Cargar un gasto y un retiro en efectivo → aparecen en Dinero y cuentan en el arqueo.
- [ ] Cerrar turno con un faltante → muestra la diferencia exacta; el turno cerrado no se puede modificar.
- [ ] Crear producto con código `000123` → se genera el código de barras. Código repetido → error claro.
- [ ] Estadísticas con filtros de fecha, medio, categoría, producto y cliente.
- [ ] Reintentar la misma venta (cortá internet un instante) → no se duplica.
- [ ] Probar en celular, tablet y PC.

## 6. Qué NO incluye todavía (Fases siguientes)

Compras y proveedores, actualización masiva de precios, importación desde Excel, devoluciones de turnos ya cerrados, modo offline y PWA instalable, balanza/etiquetas, vencimientos, despostada, facturación electrónica ARCA, usuarios adicionales (el esquema ya soporta roles), exportación CSV y respaldos desde la app.

## 7. Cosas para validar con tu contador

El sistema emite **comprobante interno “no válido como factura”**. Consultá con tu contador si podés operar así en tu situación fiscal antes de usarlo en producción.
