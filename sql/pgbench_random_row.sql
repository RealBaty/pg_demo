UPDATE hot_rows
SET counter = counter + 1
WHERE id = 1 + floor(random() * 1000)::integer;
