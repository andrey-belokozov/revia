-- seed/lou-lou.sql
-- Seed data for Lou Lou pilot client
-- Run AFTER 001_initial_schema.sql
-- Replace __LOU_LOU_2GIS_URL__ with the actual 2GIS page URL before running

BEGIN;

INSERT INTO app.clients (slug, display_name, niche, city, timezone, status)
VALUES ('lou-lou-astana', 'Lou Lou', 'restaurant', 'Астана', 'Etc/GMT-5', 'active');

INSERT INTO app.client_sources (client_id, platform, source_url, status)
VALUES (
  (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana'),
  '2gis',
  '__LOU_LOU_2GIS_URL__',
  'active'
);

INSERT INTO app.client_profiles (
  client_id, niche_template, categories, response_language, tone_config
)
VALUES (
  (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana'),
  'restaurant',
  ARRAY[
    'food_quality', 'food_taste', 'menu_variety', 'portion_size',
    'service_speed', 'service_attitude', 'staff_specific', 'atmosphere',
    'noise_level', 'cleanliness', 'price_value', 'wait_time',
    'reservation_booking', 'alcohol_drinks', 'parking', 'payment_methods'
  ],
  'auto',
  '{
    "formality": "informal_polite",
    "address_style": "first_name_polite_you",
    "use_emojis": false,
    "max_length_chars": 350,
    "default_signature": "С уважением, команда Lou Lou",
    "compensation_policy": "never_offer_without_human_approval",
    "language_preference": "match_review_language"
  }'::jsonb
);

COMMIT;
