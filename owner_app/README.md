# Dishflow Owner (mobile)

Flutter app for restaurant owners: sign in to the same reports API as
`reports.dishflow.net`, see sales / costs / open orders, and assign which
mobile reports each user may open.

```sh
cd owner_app
flutter pub get
flutter run
```

Default API base: `https://reports.dishflow.net`  
Override by constructing `OwnerApi(baseUrl: '…')` in `main.dart` for staging.
