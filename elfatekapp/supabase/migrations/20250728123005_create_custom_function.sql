-- supabase/migrations/2024XXXXXX_create_custom_function.sql

CREATE OR REPLACE FUNCTION public.hello_user(
    name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN 'Hello, ' || name;
END;
$$;