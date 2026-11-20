-- ARGYR · Caja + Gestión (kiosco / carnicería) — schema.sql
-- Fase 0: BORRADOR. Ejecutar en el SQL Editor de Supabase, en este orden:
--   1) schema.sql   2) functions.sql   3) policies.sql
-- Convenciones: dinero en centavos (bigint), cantidades numeric(12,3), ids uuid.
-- Todo lleva negocio_id (multi-negocio listo, aunque hoy sea 1 negocio / 1 usuario).

create extension if not exists pg_trgm  with schema extensions;
create extension if not exists unaccent with schema extensions;

-- Búsqueda sin acentos ni mayúsculas (immutable para poder indexarla)
create or replace function public.f_norm(t text) returns text
language sql immutable parallel safe as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, '')))
$$;

-- ───────────── Negocio y usuarios ─────────────
create table public.negocios (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null default 'ARGYR',
  cuit          text,
  condicion_iva text not null default 'monotributo',
  domicilio     text,
  logo_url      text,
  ultimo_codigo bigint not null default 0,          -- contador para sugerir códigos de producto
  config        jsonb not null default '{
    "stock_negativo": true,
    "descuento_max_cajero": 10,
    "redondeo": 0,
    "medios_activos": ["efectivo","transferencia","cuenta_corriente"],
    "delivery": false
  }'::jsonb,
  created_at    timestamptz not null default now()
);

create table public.miembros (
  user_id    uuid not null references auth.users(id) on delete cascade,
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  rol        text not null check (rol in ('dueno','encargado','cajero')),
  created_at timestamptz not null default now(),
  primary key (user_id, negocio_id)
);

-- ───────────── Catálogo ─────────────
create table public.categorias (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  nombre     text not null,
  orden      int  not null default 0,
  color      text,
  icono      text,
  activo     boolean not null default true,
  unique (negocio_id, nombre)
);

create table public.proveedores (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  nombre      text not null,
  cuit        text,
  contacto    text,
  condiciones text,
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.productos (
  id               uuid primary key default gen_random_uuid(),
  negocio_id       uuid not null references public.negocios(id) on delete cascade,
  codigo           text not null,                    -- código/artículo que elige el usuario (ej. "000123")
  nombre           text not null,
  categoria_id     uuid references public.categorias(id) on delete set null,
  proveedor_id     uuid references public.proveedores(id) on delete set null,
  unidad           text not null default 'unidad'
                   check (unidad in ('unidad','kg','g','litro','ml','paquete','caja','docena')),
  se_pesa          boolean not null default false,
  iva_pct          numeric(5,2) not null default 0 check (iva_pct >= 0),
  controla_stock   boolean not null default true,
  stock_actual     numeric(12,3) not null default 0,  -- caché mantenida por trigger (no editable a mano)
  stock_minimo     numeric(12,3) not null default 0 check (stock_minimo >= 0),
  stock_maximo     numeric(12,3) check (stock_maximo is null or stock_maximo >= 0),
  favorito         boolean not null default false,
  orden_grilla     int,
  tiene_vencimiento boolean not null default false,
  foto_url         text,
  activo           boolean not null default true,
  busqueda         text generated always as (public.f_norm(codigo || ' ' || nombre)) stored,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (negocio_id, codigo),
  check (not se_pesa or unidad in ('kg','g'))
);
create index productos_lista_idx    on public.productos (negocio_id, activo, categoria_id, nombre);
create index productos_busqueda_idx on public.productos using gin (busqueda extensions.gin_trgm_ops);
create index productos_stock_bajo_idx on public.productos (negocio_id) where controla_stock and activo;
create index productos_favoritos_idx  on public.productos (negocio_id, orden_grilla) where favorito and activo;

-- Costos aparte: el cajero NO puede leerlos (RLS solo para dueño/encargado)
create table public.producto_costos (
  producto_id    uuid primary key references public.productos(id) on delete cascade,
  negocio_id     uuid not null references public.negocios(id) on delete cascade,
  costo_ultimo   bigint not null default 0 check (costo_ultimo >= 0),
  costo_promedio bigint not null default 0 check (costo_promedio >= 0),
  updated_at     timestamptz not null default now()
);

-- Un producto puede tener varios códigos. Al crearlo se genera uno 'code128' igual a productos.codigo.
create table public.codigos_barras (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  producto_id uuid not null references public.productos(id) on delete cascade,
  codigo      text not null,
  tipo        text not null default 'code128' check (tipo in ('code128','ean13','ean8','interno','balanza')),
  unique (negocio_id, codigo)
);
create index codigos_producto_idx on public.codigos_barras (producto_id);

-- ───────────── Precios ─────────────
create table public.listas_precio (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  nombre     text not null,
  es_default boolean not null default false,
  activo     boolean not null default true,
  unique (negocio_id, nombre)
);
create unique index listas_una_default_idx on public.listas_precio (negocio_id) where es_default;

create table public.precios (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  producto_id uuid not null references public.productos(id) on delete cascade,
  lista_id    uuid not null references public.listas_precio(id) on delete cascade,
  precio      bigint not null check (precio >= 0),   -- por unidad (o por kg si se pesa)
  updated_at  timestamptz not null default now(),
  unique (producto_id, lista_id)
);

create table public.actualizaciones_precios (        -- un "lote" de actualización masiva (para deshacer)
  id           uuid primary key default gen_random_uuid(),
  negocio_id   uuid not null references public.negocios(id) on delete cascade,
  descripcion  text,
  criterio     jsonb,
  usuario      uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  revertida_at timestamptz
);

create table public.historial_precios (
  id               uuid primary key default gen_random_uuid(),
  negocio_id       uuid not null references public.negocios(id) on delete cascade,
  producto_id      uuid not null references public.productos(id) on delete cascade,
  lista_id         uuid not null references public.listas_precio(id) on delete cascade,
  precio_anterior  bigint,
  precio_nuevo     bigint not null,
  motivo           text,
  actualizacion_id uuid references public.actualizaciones_precios(id) on delete set null,
  usuario          uuid references auth.users(id),
  created_at       timestamptz not null default now()
);
create index historial_precios_prod_idx on public.historial_precios (producto_id, created_at desc);

-- ───────────── Clientes y cuenta corriente (fiado) ─────────────
create table public.clientes (
  id           uuid primary key default gen_random_uuid(),
  negocio_id   uuid not null references public.negocios(id) on delete cascade,
  nombre       text not null,
  telefono     text,
  documento    text,
  condicion_iva text not null default 'consumidor_final',
  lista_id     uuid references public.listas_precio(id) on delete set null,
  limite_cc    bigint not null default 0 check (limite_cc >= 0),
  saldo_cc     bigint not null default 0,            -- caché por trigger: lo que el cliente debe
  notas        text,
  activo       boolean not null default true,
  busqueda     text generated always as (public.f_norm(nombre || ' ' || coalesce(telefono,''))) stored,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index clientes_busqueda_idx on public.clientes using gin (busqueda extensions.gin_trgm_ops);

-- monto > 0 aumenta la deuda (venta fiada); monto < 0 la reduce (pago, anulación)
create table public.cuenta_corriente_mov (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  cliente_id uuid not null references public.clientes(id),
  tipo       text not null check (tipo in ('venta_fiada','pago','ajuste','anulacion')),
  monto      bigint not null check (monto <> 0),
  venta_id   uuid,
  medio      text check (medio is null or medio in ('efectivo','transferencia')),
  nota       text,
  usuario    uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index cc_cliente_idx on public.cuenta_corriente_mov (cliente_id, created_at desc);

-- ───────────── Cajas y turnos ─────────────
create table public.cajas (
  id            uuid primary key default gen_random_uuid(),
  negocio_id    uuid not null references public.negocios(id) on delete cascade,
  nombre        text not null default 'Caja 1',
  punto_venta   int  not null default 1,
  ultimo_numero int  not null default 0,
  activa        boolean not null default true
);

create table public.turnos_caja (
  id               uuid primary key default gen_random_uuid(),
  negocio_id       uuid not null references public.negocios(id) on delete cascade,
  caja_id          uuid not null references public.cajas(id),
  cajero_id        uuid not null references auth.users(id),
  estado           text not null default 'abierto' check (estado in ('abierto','cerrado')),
  apertura_ts      timestamptz not null default now(),
  fondo_inicial    bigint not null default 0 check (fondo_inicial >= 0),
  cierre_ts        timestamptz,
  conteo_efectivo  bigint,
  esperado_efectivo bigint,
  diferencia       bigint,                           -- conteo - esperado (negativo = faltante)
  resumen          jsonb,
  observaciones    text
);
create unique index turno_abierto_por_caja_idx on public.turnos_caja (caja_id) where estado = 'abierto';

create table public.movimientos_caja (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  turno_id   uuid not null references public.turnos_caja(id),
  tipo       text not null check (tipo in ('ingreso','egreso','retiro','gasto')),
  monto      bigint not null check (monto > 0),
  concepto   text not null,
  usuario    uuid references auth.users(id),
  ts         timestamptz not null default now()
);
create index mov_caja_turno_idx on public.movimientos_caja (turno_id);

-- ───────────── Ventas ─────────────
create table public.ventas (
  id              uuid primary key default gen_random_uuid(),
  negocio_id      uuid not null references public.negocios(id) on delete cascade,
  caja_id         uuid not null references public.cajas(id),
  turno_id        uuid not null references public.turnos_caja(id),
  numero          int  not null,                      -- correlativo por caja
  ts              timestamptz not null default now(),
  cajero_id       uuid not null references auth.users(id),
  cliente_id      uuid references public.clientes(id),
  lista_id        uuid references public.listas_precio(id),
  subtotal        bigint not null default 0 check (subtotal >= 0),
  descuento_pct   numeric(5,2) not null default 0 check (descuento_pct between 0 and 100),
  descuento_monto bigint not null default 0 check (descuento_monto >= 0),
  redondeo        bigint not null default 0,
  total           bigint not null default 0 check (total >= 0),
  estado          text not null default 'pendiente'
                  check (estado in ('pendiente','cobrada','cancelada','devuelta','en_espera')),
  notas           text,
  client_uuid     uuid not null,                      -- idempotencia (reintentos offline)
  origen          text not null default 'online' check (origen in ('online','offline')),
  anulada_por     uuid references auth.users(id),
  anulada_ts      timestamptz,
  anulada_motivo  text,
  unique (negocio_id, client_uuid),
  unique (caja_id, numero)
);
create index ventas_ts_idx    on public.ventas (negocio_id, ts desc);
create index ventas_turno_idx on public.ventas (turno_id);
create index ventas_cliente_idx on public.ventas (cliente_id) where cliente_id is not null;

create table public.venta_items (
  id             uuid primary key default gen_random_uuid(),
  negocio_id     uuid not null references public.negocios(id) on delete cascade,
  venta_id       uuid not null references public.ventas(id) on delete cascade,
  producto_id    uuid not null references public.productos(id),
  orden          int  not null default 0,
  nombre         text not null,                       -- SNAPSHOT
  unidad         text not null,                       -- SNAPSHOT
  cantidad       numeric(12,3) not null check (cantidad > 0),
  precio_unit    bigint not null check (precio_unit >= 0),   -- SNAPSHOT
  iva_pct        numeric(5,2) not null default 0,            -- SNAPSHOT
  descuento_linea bigint not null default 0 check (descuento_linea >= 0),
  total          bigint not null check (total >= 0)          -- round(cantidad*precio_unit) - descuento_linea
);
create index venta_items_venta_idx    on public.venta_items (venta_id);
create index venta_items_producto_idx on public.venta_items (producto_id);

-- Costo congelado de cada línea: aparte para que el cajero no lo vea
create table public.venta_item_costos (
  venta_item_id uuid primary key references public.venta_items(id) on delete cascade,
  negocio_id    uuid not null references public.negocios(id) on delete cascade,
  costo_unit    bigint not null default 0 check (costo_unit >= 0)
);

create table public.pagos (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  venta_id   uuid not null references public.ventas(id) on delete cascade,
  medio      text not null
             check (medio in ('efectivo','transferencia','debito','credito','qr','cuenta_corriente')),
  monto      bigint not null check (monto > 0),       -- monto aplicado a la venta
  entregado  bigint,                                  -- efectivo recibido (si hubo vuelto)
  vuelto     bigint not null default 0 check (vuelto >= 0),
  referencia text,
  ts         timestamptz not null default now()
);
create index pagos_venta_idx on public.pagos (venta_id);

-- ───────────── Stock ─────────────
create table public.stock_movimientos (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  tipo        text not null check (tipo in
              ('compra','venta','ajuste','merma','devolucion','despostada','inventario','transferencia')),
  cantidad    numeric(12,3) not null check (cantidad <> 0),   -- con signo
  costo_unit  bigint,
  ref_tipo    text,
  ref_id      uuid,
  usuario     uuid references auth.users(id),
  nota        text,
  ts          timestamptz not null default now()
);
create index stock_mov_prod_idx on public.stock_movimientos (producto_id, ts desc);

-- ───────────── Compras y proveedores ─────────────
create table public.compras (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  proveedor_id uuid references public.proveedores(id),
  fecha       date not null default current_date,
  comprobante text,
  total       bigint not null default 0 check (total >= 0),
  pagado      bigint not null default 0 check (pagado >= 0),
  estado      text not null default 'borrador' check (estado in ('borrador','confirmada','anulada')),
  notas       text,
  created_at  timestamptz not null default now()
);

create table public.compra_items (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  compra_id   uuid not null references public.compras(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  cantidad    numeric(12,3) not null check (cantidad > 0),
  costo_unit  bigint not null check (costo_unit >= 0),
  iva_pct     numeric(5,2) not null default 0,
  total       bigint not null check (total >= 0)
);

create table public.pagos_proveedor (
  id           uuid primary key default gen_random_uuid(),
  negocio_id   uuid not null references public.negocios(id) on delete cascade,
  proveedor_id uuid not null references public.proveedores(id),
  compra_id    uuid references public.compras(id),
  monto        bigint not null check (monto > 0),
  medio        text not null check (medio in ('efectivo','transferencia')),
  fecha        date not null default current_date,
  nota         text
);

-- ───────────── Dinero: gastos y haberes (heredados de ARGYR) ─────────────
create table public.gastos (
  id          uuid primary key default gen_random_uuid(),
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  fecha       date not null default current_date,
  categoria   text not null,
  descripcion text,
  clase       text not null default 'variable' check (clase in ('fijo','variable')),
  cuenta      text not null default 'efectivo' check (cuenta in ('efectivo','banco','billetera')),
  monto       bigint not null check (monto > 0),
  proveedor_id uuid references public.proveedores(id),
  items       jsonb,
  created_at  timestamptz not null default now()
);

create table public.haberes (
  id         uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  fecha      date not null default current_date,
  persona    text not null,
  tipo       text not null default 'sueldo' check (tipo in ('sueldo','adelanto','retiro')),
  cuenta     text not null default 'efectivo' check (cuenta in ('efectivo','banco','billetera')),
  monto      bigint not null check (monto > 0),
  nota       text
);

-- ───────────── Fiscal (vacío hasta la Fase 4) y auditoría ─────────────
create table public.comprobantes_fiscales (
  id           uuid primary key default gen_random_uuid(),
  negocio_id   uuid not null references public.negocios(id) on delete cascade,
  venta_id     uuid not null references public.ventas(id),
  tipo         text not null check (tipo in ('A','B','C','NC_A','NC_B','NC_C','interno')),
  punto_venta  int,
  numero       bigint,
  cae          text,
  cae_vto      date,
  estado       text not null default 'pendiente' check (estado in ('pendiente','emitido','error')),
  respuesta    jsonb,
  created_at   timestamptz not null default now()
);

create table public.auditoria (
  id         bigint generated always as identity primary key,
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  usuario    uuid references auth.users(id),
  accion     text not null,
  entidad    text not null,
  entidad_id uuid,
  antes      jsonb,
  despues    jsonb,
  ts         timestamptz not null default now()
);
create index auditoria_ts_idx on public.auditoria (negocio_id, ts desc);
