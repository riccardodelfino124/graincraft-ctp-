# Auth Setup

1. Create the first email/password user in Supabase Auth.
2. Sign in once so the `profiles` trigger creates a profile row.
3. In Supabase SQL Editor, assign the first admin:

```sql
update public.profiles
set role = 'admin', display_name = coalesce(display_name, 'Admin')
where user_id = '<auth-user-uuid>';
```

4. Sign in to the application with that email and password.
5. Use the profile role to grant `manager` or `admin` to other users where practical.
