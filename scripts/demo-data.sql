-- demo-data.sql — 30 days of synthetic history for the observability demo.
-- Idempotent (skips when demo_seed_marker exists). Run via scripts/seed-data.sh.

BEGIN;

CREATE TABLE IF NOT EXISTS demo_seed_marker (seeded_at timestamptz PRIMARY KEY);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM demo_seed_marker) THEN
    RAISE EXCEPTION 'demo data already seeded';
  END IF;
END $$;

-- demo users (45), across the last 30 days.
-- NOTE: roles are NOT a users column (they live in the user_roles join
-- table) — the role rows are seeded right after.
INSERT INTO users (id, email, email_lookup, password_hash, name, email_verified,
                   email_verification_token, two_factor_enabled, created_at, updated_at)
SELECT
  gen_random_uuid()::text,
  lower('demo' || n || '@iloveshopping.ke'),
  md5(random()::text),
  '$2a$12$demo.invalid.demo.invalid.demo.invalid.demo.invalid.d',
  'Demo Customer ' || n,
  now() - (random() * interval '30 days'),
  NULL,
  false,
  now() - (random() * interval '30 days'),
  now() - (random() * interval '30 days')
FROM generate_series(1, 45) AS n;

-- every demo user is a plain USER
INSERT INTO user_roles (user_id, role)
SELECT id, 'USER' FROM users
WHERE email LIKE 'demo%@iloveshopping.ke'
  AND NOT EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = users.id);

-- 120 orders with items + payment rows, mixed types and statuses
DO $demo$
DECLARE
  i    int;
  p    record;
  qty  int;
  sub  decimal(10,2);
  taxamt decimal(10,2);
  ship decimal(10,2);
  tot  decimal(10,2);
  st   text;
  uid  text;
  gid  text;
  oid  text;
  itid text;
  when_ timestamptz;
  prov text;
BEGIN
  FOR i IN 1..120 LOOP
    SELECT * FROM products WHERE is_active ORDER BY random() LIMIT 1 INTO p;
    CONTINUE WHEN p IS NULL;

    qty  := 1 + floor(random()*3)::int;
    sub  := p.price * qty;
    taxamt := round(sub * 0.16, 2);
    ship := CASE WHEN sub > 5000 THEN 0 ELSE 200 END;
    tot  := sub + taxamt + ship;

    -- the pool deliberately contains stale PENDING/EXPIRED orders so the
    -- cart-abandonment gauge reads meaningful history from day one
    st := (ARRAY['CONFIRMED','CONFIRMED','DELIVERED','DELIVERED','PROCESSING','SHIPPED','REFUNDED','PENDING','EXPIRED','PENDING'])[floor(random()*10+1)];

    IF random() < 0.55 THEN
      SELECT id FROM users ORDER BY random() LIMIT 1 INTO uid;
      gid := NULL;
    ELSE
      uid := NULL;
      gid := lower('guest' || floor(random()*30)::text || '@iloveshopping.ke');
    END IF;

    oid := gen_random_uuid()::text;
    when_ := now() - (random() * interval '30 days');

    INSERT INTO orders (
      id, number, user_id, guest_email, cart_session_id, status,
      subtotal, tax, shipping, total, currency,
      shipping_address, billing_address, shipping_method, notes, created_at, updated_at
    ) VALUES (
      oid,
      'DEMO-' || upper(encode(gen_random_bytes(4), 'hex')),
      uid, gid,
      CASE WHEN gid IS NOT NULL THEN 'guest-sess-' || floor(random()*120)::text ELSE NULL END,
      st,
      sub, taxamt, ship, tot, 'KES',
      '{"name":"Demo Shopper","line1":"1 Demo Avenue","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"}',
      '{"name":"Demo Shopper","line1":"1 Demo Avenue","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"}',
      'Standard delivery',
      NULL, when_, when_
    );

    itid := gen_random_uuid()::text;
    INSERT INTO order_items (id, order_id, product_id, name, price, quantity, total, created_at)
    VALUES (itid, oid, p.id, p.name, p.price, qty, p.price * qty, when_);

    -- payments: paid orders SUCCEEDED, refunds REFUNDED, and the stale
    -- PENDING/EXPIRED ones carry a FAILED attempt with a realistic reason
    -- so the payment-failure analysis panel has history too.
    IF st IN ('PENDING', 'EXPIRED') THEN
      prov := CASE WHEN random() < 0.5 THEN 'MPESA' ELSE 'STRIPE' END;
      INSERT INTO payments (
        id, order_id, provider, provider_id, amount, currency, status,
        metadata, created_at, updated_at
      ) VALUES (
        gen_random_uuid()::text, oid, prov, 'demo-pay-' || i, tot, 'KES', 'FAILED',
        jsonb_build_object('reason',
          (ARRAY['stk_timeout','callback_failure','card_declined','insufficient_funds','amount_mismatch'])[floor(random()*5+1)]),
        when_ + interval '2 minutes', when_ + interval '2 minutes'
      );
    ELSIF st <> 'CANCELLED' THEN
      prov := CASE WHEN random() < 0.5 THEN 'MPESA' ELSE 'STRIPE' END;
      INSERT INTO payments (
        id, order_id, provider, provider_id, amount, currency, status,
        metadata, created_at, updated_at
      ) VALUES (
        gen_random_uuid()::text, oid, prov, 'demo-pay-' || i, tot, 'KES',
        CASE WHEN st = 'REFUNDED' THEN 'REFUNDED' ELSE 'SUCCEEDED' END,
        NULL, when_ + interval '2 minutes', when_ + interval '2 minutes'
      );
    END IF;
  END LOOP;
END $demo$;

-- reviews for the same products, weighted toward positive ratings
WITH demo_revs AS (
  SELECT p.id AS product_id, u.id AS user_id, now() - (random() * interval '30 days') AS ts,
         3 + floor(random()*3)::int AS rating
  FROM products p CROSS JOIN generate_series(1, 3) s,
       LATERAL (SELECT id FROM users ORDER BY random() LIMIT 1) u
  WHERE p.is_active
)
INSERT INTO reviews (id, product_id, user_id, rating, title, content, is_verified_purchase, helpful_count, status, created_at, updated_at)
SELECT
  gen_random_uuid()::text,
  r.product_id, r.user_id, r.rating,
  'Demo review',
  'Demo review content exercising the moderation metrics.',
  false, floor(random()*12)::int, 'APPROVED', r.ts, r.ts
FROM demo_revs r;

INSERT INTO demo_seed_marker (seeded_at) VALUES (now());

COMMIT;
