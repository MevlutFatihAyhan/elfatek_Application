INSERT INTO public.users (id, name, surname, email, password, institution_id, is_admin, created_at)
SELECT 
  id,
  split_part(COALESCE(raw_user_meta_data->>'full_name', ''), ' ', 1) AS name,
  split_part(COALESCE(raw_user_meta_data->>'full_name', ''), ' ', 2) AS surname,
  email,
  '', -- password boş bırakılıyor veya NULL yapabilirsiniz (sütun izin veriyorsa)
  concat('ID-', substring(id::text, 1, 8)) AS institution_id,
  FALSE AS is_admin,
  created_at
FROM auth.users
WHERE id NOT IN (SELECT id FROM public.users);
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.users (
    id, name, surname, email, password, institution_id, is_admin, created_at
  )
  VALUES (
    NEW.id,
    split_part(COALESCE(NEW.raw_user_meta_data->>'full_name', ''), ' ', 1),
    split_part(COALESCE(NEW.raw_user_meta_data->>'full_name', ''), ' ', 2),
    NEW.email,
    '', -- şifre boş bırakıldı, dilersen null veya dummy hash koy
    concat('ID-', substring(NEW.id::text, 1, 8)),
    FALSE,
    now()
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
