DROP TRIGGER IF EXISTS on_auth_user_created ON users;
DROP FUNCTION IF EXISTS handle_new_user();
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
    crypt('defaultPassword123!', gen_salt('bf')), -- Şifre için dummy hash (örnek)
    concat('ID-', substring(NEW.id::text, 1, 8)),
    FALSE,
    now()
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;