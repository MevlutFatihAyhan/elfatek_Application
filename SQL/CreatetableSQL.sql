CREATE TABLE projects (
    project_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), -- Benzersiz proje kimliği
    project_name VARCHAR(255) UNIQUE NOT NULL, -- Proje adı (benzersiz olmalı)
    storage_path VARCHAR(255) UNIQUE NOT NULL, -- Supabase Storage'daki ana klasör yolu (ör: 'STM/JOY')
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);
CREATE TABLE versions (
    version_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), -- Benzersiz versiyon kimliği
    project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE, -- Hangi projeye ait olduğu
    version_name VARCHAR(100) NOT NULL, -- Versiyon adı (ör: 'v1', 'revA')
    storage_path VARCHAR(255) UNIQUE NOT NULL, -- Supabase Storage'daki versiyon klasörünün tam yolu (ör: 'STM/JOY/v1')
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    
    UNIQUE (project_id, version_name) -- Bir projenin aynı isimde iki versiyonu olamaz
);

CREATE TABLE user_projects (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, -- Kullanıcı kimliği
    project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE, -- Proje kimliği
    PRIMARY KEY (user_id, project_id), -- İki sütunun birleşimi benzersiz olmalı
    assigned_at TIMESTAMPTZ DEFAULT now() NOT NULL
);
CREATE TABLE users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, 
    name VARCHAR(100) NOT NULL,
    surname VARCHAR(100) NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL, -- Şifre hash'lenmiş olmalı
    institution_id VARCHAR(50) UNIQUE NOT NULL,
    is_admin BOOLEAN DEFAULT FALSE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    deleted_at TIMESTAMPTZ
);
