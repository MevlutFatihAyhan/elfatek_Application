import jwt
from functools import wraps
from flask import request, jsonify
from supabase import create_client
from config import SUPABASE_URL, SUPABASE_KEY, LEGACY_JWT_SECRET

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get('Authorization', None)
        if not auth_header or not auth_header.startswith("Bearer "):
            return jsonify({"error": "Token gerekli"}), 401

        token = auth_header.split(" ")[1]

        try:
            decoded = jwt.decode(
                token,
                LEGACY_JWT_SECRET,
                algorithms=["HS256"],
                options={"verify_aud": False}  
            )

            user_id = decoded.get("sub")
            if not user_id:
                return jsonify({"error": "Token içinde kullanıcı bilgisi yok"}), 401

            user_data = supabase.table('users').select("id, is_admin").eq("id", user_id).execute()
            if not user_data.data or len(user_data.data) == 0:
                return jsonify({"error": "Kullanıcı bulunamadı"}), 401
            print("Token decode oldu:", decoded)
            print("Kullanıcı ID:", user_id)
            print("Supabase kullanıcı verisi:", user_data.data)
            user = user_data.data[0]
            return f(user, *args, **kwargs)

        except jwt.ExpiredSignatureError:
            return jsonify({"error": "Token süresi dolmuş"}), 401
        except jwt.InvalidTokenError as e:
            return jsonify({"error": f"Geçersiz token: {str(e)}"}), 401

    return decorated
