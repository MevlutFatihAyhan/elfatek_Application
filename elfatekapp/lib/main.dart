import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_page.dart';
import 'screens/project_page.dart';

final supabase = Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://kombdtrogdebmyogsstc.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtvbWJkdHJvZ2RlYm15b2dzc3RjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTM2Njg5OTAsImV4cCI6MjA2OTI0NDk5MH0.UqLaMzjuFkvEouKmEmNDcCRsbU0ijmJilvN8uC-wGTs',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Elfatek App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const LoginScreen(),
      routes: {
        '/projectTree': (context) {
          final args =
              ModalRoute.of(context)!.settings.arguments
                  as Map<String, dynamic>?;
          final username = args?['username'] ?? 'Kullanıcı';
          final isAdmin = args?['isAdmin'] ?? false;

          debugPrint('User: $username, IsAdmin: $isAdmin');

          return ProjectPage(username: username, isAdmin: isAdmin);
        },
      },
    );
  }
}
