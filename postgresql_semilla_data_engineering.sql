-- ============================================================
-- Semilla de datos para la clase: PostgreSQL para Data Engineering
-- Compatible con PostgreSQL 14+
-- Genera: 200 clientes y 50.000 ventas reproducibles.
-- Uso: psql -U usuario -d base_de_datos -f postgresql_semilla_data_engineering.sql
-- ============================================================

BEGIN;

DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    email        VARCHAR(180) NOT NULL UNIQUE,
    city         VARCHAR(80) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sales (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id          VARCHAR(40) NOT NULL UNIQUE,
    customer_id       BIGINT NOT NULL REFERENCES customers(id),
    product_category  VARCHAR(40) NOT NULL,
    amount            NUMERIC(12, 2) NOT NULL CHECK (amount >= 0),
    status            VARCHAR(20) NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL,
    updated_at        TIMESTAMPTZ NOT NULL
);

-- 200 clientes ficticios.
INSERT INTO customers (full_name, email, city, created_at, updated_at)
SELECT
    'Cliente ' || LPAD(g::text, 4, '0'),
    'cliente' || g || '@example.com',
    (ARRAY['Bogotá', 'Medellín', 'Cali', 'Barranquilla', 'Cartagena', 'Bucaramanga'])[((g - 1) % 6) + 1],
    NOW() - ((g % 700) || ' days')::interval,
    NOW() - ((g % 90) || ' days')::interval
FROM generate_series(1, 200) AS g;

-- 50.000 ventas con fechas distribuidas en los últimos 18 meses.
-- Se fija la semilla de random() para facilitar una demostración repetible.
SELECT setseed(0.42);

INSERT INTO sales (
    order_id, customer_id, product_category, amount, status, created_at, updated_at
)
SELECT
    'ORD-' || LPAD(g::text, 8, '0'),
    1 + floor(random() * 200)::BIGINT,
    (ARRAY['Tecnología', 'Hogar', 'Deportes', 'Ropa', 'Libros'])[(1 + floor(random() * 5))::int],
    ROUND((10000 + random() * 990000)::numeric, 2),
    (ARRAY['paid', 'paid', 'paid', 'pending', 'cancelled'])[(1 + floor(random() * 5))::int],
    NOW() - (random() * INTERVAL '540 days'),
    NOW() - (random() * INTERVAL '180 days')
FROM generate_series(1, 50000) AS g;

-- Asegura que updated_at nunca sea anterior a created_at.
UPDATE sales
SET updated_at = created_at + (random() * INTERVAL '30 days')
WHERE updated_at < created_at;

-- Índices iniciales para relaciones y consultas comunes.
-- En la diapositiva de rendimiento, compara planes antes/después de crear
-- un índice específico sobre created_at o updated_at.
CREATE INDEX idx_sales_customer_id ON sales(customer_id);
CREATE INDEX idx_sales_category_created_at ON sales(product_category, created_at);

COMMIT;

ANALYZE customers;
ANALYZE sales;

-- ============================================================
-- CONSULTAS PARA VISUALIZAR LOS TEMAS DE LA PRESENTACIÓN
-- Ejecuta cada bloque por separado.
-- ============================================================

-- 1. Comprobar el volumen creado
SELECT 'customers' AS tabla, COUNT(*) AS registros FROM customers
UNION ALL
SELECT 'sales', COUNT(*) FROM sales;

-- 2. JOIN + agregaciones: ventas por cliente
SELECT
    c.id,
    c.full_name,
    COUNT(s.id) AS total_ordenes,
    COALESCE(SUM(s.amount), 0) AS valor_total,
    ROUND(COALESCE(AVG(s.amount), 0), 2) AS valor_promedio
FROM customers c
LEFT JOIN sales s ON s.customer_id = c.id
GROUP BY c.id, c.full_name
ORDER BY valor_total DESC
LIMIT 10;

-- 3. Ventas por categoría y día
SELECT
    DATE_TRUNC('day', created_at)::date AS dia,
    product_category,
    COUNT(*) AS cantidad_ventas,
    ROUND(SUM(amount), 2) AS total_ventas,
    ROUND(AVG(amount), 2) AS promedio_venta
FROM sales
GROUP BY 1, 2
ORDER BY dia DESC, total_ventas DESC
LIMIT 30;

-- 4. Función de ventana: venta más reciente de cada cliente
WITH ranked_sales AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY created_at DESC, id DESC
        ) AS row_num
    FROM sales s
)
SELECT customer_id, order_id, product_category, amount, created_at
FROM ranked_sales
WHERE row_num = 1
ORDER BY customer_id
LIMIT 20;

-- 5. LAG: comparar cada venta con la venta anterior del cliente
SELECT customer_id, order_id, created_at, amount,
       LAG(amount) OVER (
           PARTITION BY customer_id ORDER BY created_at, id
       ) AS monto_venta_anterior
FROM sales
WHERE customer_id = 1
ORDER BY created_at, id
LIMIT 20;

-- 6. Plan de ejecución. Ejecuta antes y después de crear el índice sugerido.
EXPLAIN ANALYZE
SELECT id, order_id, amount, created_at
FROM sales
WHERE created_at >= NOW() - INTERVAL '7 days';

-- Prueba opcional de índice para comparar el plan anterior:
-- CREATE INDEX idx_sales_created_at ON sales(created_at);
-- ANALYZE sales;
-- EXPLAIN ANALYZE
-- SELECT id, order_id, amount, created_at
-- FROM sales
-- WHERE created_at >= NOW() - INTERVAL '7 days';

-- 7. Extracción incremental: reemplaza las fechas por el intervalo de tu ejercicio.
-- Usa un intervalo [inicio, fin) para no solapar los límites entre lotes.
SELECT id, order_id, customer_id, amount, created_at, updated_at
FROM sales
WHERE updated_at >= NOW() - INTERVAL '2 days'
  AND updated_at < NOW()
ORDER BY updated_at, id;

-- 8. UPSERT de demostración. La clave order_id tiene restricción UNIQUE.
INSERT INTO sales (
    order_id, customer_id, product_category, amount, status, created_at, updated_at
)
VALUES (
    'ORD-DEMO-0001', 1, 'Tecnología', 125000.00, 'paid', NOW(), NOW()
)
ON CONFLICT (order_id)
DO UPDATE SET
    amount = EXCLUDED.amount,
    status = EXCLUDED.status,
    updated_at = NOW();

-- Ejecuta el mismo UPSERT dos veces y comprueba que no crea dos filas:
-- SELECT order_id, COUNT(*) FROM sales
-- WHERE order_id = 'ORD-DEMO-0001'
-- GROUP BY order_id;

-- 9. Transacción: prueba COMMIT o reemplaza COMMIT por ROLLBACK.
-- BEGIN;
-- UPDATE sales SET amount = amount + 1000, updated_at = NOW() WHERE id = 1;
-- SELECT id, amount FROM sales WHERE id = 1;
-- ROLLBACK;

-- 10. Distribución general para explorar los datos
SELECT status, product_category, COUNT(*) AS cantidad,
       ROUND(SUM(amount), 2) AS total
FROM sales
GROUP BY status, product_category
ORDER BY status, total DESC;
