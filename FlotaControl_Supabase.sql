-- ============================================================
-- FLOTACONTROL — Script SQL para Supabase
-- Ejecutar completo en: Supabase → SQL Editor → New Query
-- ============================================================

-- ── 1. EXTENSION UUID ─────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- ── 2. TABLA: usuarios (manejada por Supabase Auth)
--    Solo agregamos perfil con nombre y rol
-- ============================================================
CREATE TABLE IF NOT EXISTS public.perfiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre      TEXT NOT NULL,
  rol         TEXT NOT NULL DEFAULT 'Operador' CHECK (rol IN ('Administrador','Operador')),
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Trigger: crear perfil automático al registrar usuario ──
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.perfiles (id, nombre, rol)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'nombre', NEW.email), 'Operador');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- ── 3. TABLA: vehiculos
-- ============================================================
CREATE TABLE IF NOT EXISTS public.vehiculos (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  placa             TEXT NOT NULL UNIQUE,
  flota             INTEGER NOT NULL CHECK (flota IN (1, 2)),
  conductor_habitual TEXT DEFAULT 'Sin asignar',
  estado            TEXT DEFAULT 'Operativo' CHECK (estado IN (
                      'Operativo',
                      'En taller',
                      'En mantenimiento preventivo',
                      'Fuera de servicio',
                      'Pendiente revisión'
                    )),
  proximo_servicio  DATE,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

-- ── Insertar todas las placas automáticamente ──────────────

-- Flota 1 (27 placas)
INSERT INTO public.vehiculos (placa, flota) VALUES
  ('LQO621', 1), ('LWL839', 1), ('LWL924', 1), ('LWL846', 1),
  ('LWL845', 1), ('LWL847', 1), ('LQO594', 1), ('LQO622', 1),
  ('LQO634', 1), ('LQO796', 1), ('LQO807', 1), ('LWL838', 1),
  ('LWL840', 1), ('LWL841', 1), ('LWL914', 1), ('LWL925', 1),
  ('LWL926', 1), ('JTZ522', 1), ('LQO777', 1), ('LWL844', 1),
  ('LQO618', 1), ('LQO617', 1), ('LQO624', 1), ('LQO736', 1),
  ('LWL842', 1), ('LWL843', 1), ('MYY332', 1)
ON CONFLICT (placa) DO NOTHING;

-- Flota 2 (14 placas)
INSERT INTO public.vehiculos (placa, flota) VALUES
  ('LGU591', 2), ('JOW478', 2), ('PMU881', 2), ('LGU585', 2),
  ('WFR893', 2), ('JOX279', 2), ('SXV372', 2), ('WFR744', 2),
  ('SXV117', 2), ('TNH022', 2), ('WFR892', 2), ('JOU575', 2),
  ('VCM156', 2), ('VKK444', 2)
ON CONFLICT (placa) DO NOTHING;

-- ── Trigger: actualizar updated_at automáticamente ────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vehiculos_updated
  BEFORE UPDATE ON public.vehiculos
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- ── 4. TABLA: mantenimientos (unifica flota 1 y flota 2)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.mantenimientos (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehiculo_id       UUID NOT NULL REFERENCES public.vehiculos(id) ON DELETE CASCADE,
  placa             TEXT NOT NULL,
  flota             INTEGER NOT NULL,

  -- Tiempos
  fecha_entrada     DATE NOT NULL,
  hora_entrada      TIME,
  fecha_salida      DATE,
  hora_salida       TIME,
  horas_taller      NUMERIC(8,2) GENERATED ALWAYS AS (
                      CASE
                        WHEN fecha_salida IS NOT NULL AND hora_entrada IS NOT NULL AND hora_salida IS NOT NULL
                          THEN EXTRACT(EPOCH FROM (
                            (fecha_salida + hora_salida) - (fecha_entrada + hora_entrada)
                          )) / 3600
                        WHEN fecha_salida IS NOT NULL
                          THEN (fecha_salida - fecha_entrada) * 24.0
                        ELSE NULL
                      END
                    ) STORED,

  -- Datos vehículo
  conductor         TEXT,
  km_ingreso        INTEGER,
  tipo_mantenimiento TEXT,
  descripcion       TEXT,
  novedades         TEXT,

  -- Solo Flota 1
  asistencia_via    BOOLEAN DEFAULT FALSE,
  tiempo_reaccion   TEXT,

  -- Solo Flota 2
  num_factura       TEXT,
  valor_factura     NUMERIC(14,2),
  fecha_servicio    DATE,
  nombre_proveedor  TEXT,
  factura_pagada    TEXT DEFAULT 'Pendiente' CHECK (factura_pagada IN ('Pagada','Pendiente','No pagada')),

  -- Archivos (URLs de Supabase Storage)
  evidencia_url     TEXT,
  soporte_factura_url TEXT,

  -- Meta
  registrado_por    UUID REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_mantenimientos_updated
  BEFORE UPDATE ON public.mantenimientos
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── Índices para búsquedas rápidas ────────────────────────
CREATE INDEX IF NOT EXISTS idx_mant_placa        ON public.mantenimientos(placa);
CREATE INDEX IF NOT EXISTS idx_mant_vehiculo     ON public.mantenimientos(vehiculo_id);
CREATE INDEX IF NOT EXISTS idx_mant_fecha        ON public.mantenimientos(fecha_entrada DESC);
CREATE INDEX IF NOT EXISTS idx_mant_flota        ON public.mantenimientos(flota);
CREATE INDEX IF NOT EXISTS idx_mant_pago         ON public.mantenimientos(factura_pagada);

-- ============================================================
-- ── 5. VISTA: resumen por vehículo (reemplaza el Excel resumen)
-- ============================================================
CREATE OR REPLACE VIEW public.v_resumen_flota AS
SELECT
  v.id,
  v.placa,
  v.flota,
  v.conductor_habitual,
  v.estado,
  v.proximo_servicio,

  -- Último mantenimiento
  ult.fecha_entrada       AS ult_fecha_entrada,
  ult.fecha_salida        AS ult_fecha_salida,
  ult.conductor           AS ult_conductor,
  ult.km_ingreso          AS ult_km,
  ult.tipo_mantenimiento  AS ult_tipo_mant,
  ult.horas_taller        AS ult_horas_taller,
  ult.novedades           AS ult_novedades,
  ult.nombre_proveedor    AS ult_proveedor,
  ult.factura_pagada      AS ult_estado_pago,
  ult.num_factura         AS ult_num_factura,
  ult.valor_factura       AS ult_valor_factura,

  -- Totales acumulados
  COALESCE(stats.total_registros, 0)  AS total_registros,
  COALESCE(stats.total_horas, 0)      AS total_horas_taller,
  COALESCE(stats.total_facturado, 0)  AS total_facturado,
  COALESCE(stats.fact_pendientes, 0)  AS facturas_pendientes,

  -- Días hasta próximo servicio
  (v.proximo_servicio - CURRENT_DATE) AS dias_para_servicio

FROM public.vehiculos v

-- Último mantenimiento por vehículo
LEFT JOIN LATERAL (
  SELECT * FROM public.mantenimientos m
  WHERE m.vehiculo_id = v.id
  ORDER BY m.fecha_entrada DESC, m.created_at DESC
  LIMIT 1
) ult ON TRUE

-- Estadísticas acumuladas
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                          AS total_registros,
    SUM(horas_taller)                                 AS total_horas,
    SUM(CASE WHEN flota = 2 THEN valor_factura ELSE 0 END) AS total_facturado,
    COUNT(CASE WHEN factura_pagada IN ('Pendiente','No pagada') THEN 1 END) AS fact_pendientes
  FROM public.mantenimientos m
  WHERE m.vehiculo_id = v.id
) stats ON TRUE

ORDER BY v.flota, v.placa;

-- ============================================================
-- ── 6. STORAGE: buckets para archivos
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('evidencias', 'evidencias', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('facturas', 'facturas', false)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- ── 7. ROW LEVEL SECURITY (RLS) — Control de acceso
-- ============================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE public.perfiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehiculos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mantenimientos ENABLE ROW LEVEL SECURITY;

-- ── Políticas: cualquier usuario autenticado puede leer ────
CREATE POLICY "Lectura autenticados - vehiculos"
  ON public.vehiculos FOR SELECT
  TO authenticated USING (true);

CREATE POLICY "Lectura autenticados - mantenimientos"
  ON public.mantenimientos FOR SELECT
  TO authenticated USING (true);

CREATE POLICY "Lectura autenticados - perfiles"
  ON public.perfiles FOR SELECT
  TO authenticated USING (true);

-- ── Políticas: solo autenticados pueden insertar/editar ───
CREATE POLICY "Insertar autenticados - mantenimientos"
  ON public.mantenimientos FOR INSERT
  TO authenticated WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Editar autenticados - mantenimientos"
  ON public.mantenimientos FOR UPDATE
  TO authenticated USING (auth.uid() IS NOT NULL);

CREATE POLICY "Editar autenticados - vehiculos"
  ON public.vehiculos FOR UPDATE
  TO authenticated USING (auth.uid() IS NOT NULL);

-- ── Políticas de Storage ───────────────────────────────────
CREATE POLICY "Subir evidencias"
  ON storage.objects FOR INSERT
  TO authenticated WITH CHECK (bucket_id IN ('evidencias','facturas'));

CREATE POLICY "Ver archivos propios"
  ON storage.objects FOR SELECT
  TO authenticated USING (bucket_id IN ('evidencias','facturas'));

-- ============================================================
-- ── 8. FUNCIÓN: resumen de alertas (próximos servicios)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_alertas(dias_limite INTEGER DEFAULT 7)
RETURNS TABLE (
  placa TEXT, flota INTEGER, conductor_habitual TEXT,
  proximo_servicio DATE, dias_restantes INTEGER, estado TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    v.placa, v.flota, v.conductor_habitual,
    v.proximo_servicio,
    (v.proximo_servicio - CURRENT_DATE)::INTEGER AS dias_restantes,
    v.estado
  FROM public.vehiculos v
  WHERE v.proximo_servicio IS NOT NULL
    AND (v.proximo_servicio - CURRENT_DATE) <= dias_limite
  ORDER BY v.proximo_servicio ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- ── 9. CREAR USUARIOS INICIALES
--    (ejecutar DESPUÉS de crear el proyecto en Supabase Auth)
-- ============================================================
-- Nota: los usuarios se crean desde Authentication → Users
-- o usando este SQL (reemplaza los correos y contraseñas):
--
-- SELECT auth.sign_up('admin@tuempresa.com',    'flota2024');
-- SELECT auth.sign_up('andres@tuempresa.com',   'andres123');
-- SELECT auth.sign_up('william@tuempresa.com',  'william123');
--
-- Luego actualiza sus roles en la tabla perfiles:
-- UPDATE public.perfiles SET rol = 'Administrador', nombre = 'Admin'
--   WHERE id = (SELECT id FROM auth.users WHERE email = 'admin@tuempresa.com');
-- UPDATE public.perfiles SET nombre = 'Andrés'
--   WHERE id = (SELECT id FROM auth.users WHERE email = 'andres@tuempresa.com');
-- UPDATE public.perfiles SET nombre = 'William'
--   WHERE id = (SELECT id FROM auth.users WHERE email = 'william@tuempresa.com');

-- ============================================================
-- ✅ VERIFICACIÓN FINAL
-- ============================================================
SELECT 'vehiculos'      AS tabla, COUNT(*) AS registros FROM public.vehiculos
UNION ALL
SELECT 'mantenimientos' AS tabla, COUNT(*) AS registros FROM public.mantenimientos
UNION ALL
SELECT 'perfiles'       AS tabla, COUNT(*) AS registros FROM public.perfiles;

-- Debe mostrar: vehiculos=41, mantenimientos=0, perfiles=0
-- ¡Listo! Ahora conecta la app con tu URL y anon key de Supabase.
