import 'package:flutter/material.dart';

class LocaleController extends ValueNotifier<Locale> {
  LocaleController([super.value = const Locale('en')]);

  bool get isArabic => value.languageCode == 'ar';

  void toggle() => value = Locale(isArabic ? 'en' : 'ar');
}

String tr(BuildContext context, String en) {
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  if (!ar) return en;
  return _ar[en] ?? en;
}

const _ar = <String, String>{
  'Reports site': 'موقع التقارير',
  'Sign in to your account': 'سجّل الدخول لحسابك',
  'Username': 'اسم المستخدم',
  'Password': 'كلمة المرور',
  'Enter username': 'أدخل اسم المستخدم',
  'Enter password': 'أدخل كلمة المرور',
  'Sign in': 'دخول',
  'Welcome': 'أهلاً',
  'Reports': 'التقارير',
  'Today': 'اليوم',
  'Yesterday': 'أمس',
  'Last 7 days': 'آخر 7 أيام',
  'Net sales': 'صافي المبيعات',
  'Orders': 'الطلبات',
  'Average check': 'متوسط الفاتورة',
  'Returns': 'المرتجعات',
  'Cost': 'التكلفة',
  'Margin': 'الهامش',
  'Open orders': 'الطلبات المفتوحة',
  'Open value': 'قيمة المفتوحة',
  'Sales summary': 'ملخص المبيعات',
  'Sales detail': 'تفاصيل المبيعات',
  'Costs & margins': 'التكلفة والهامش',
  'Order detail': 'تفاصيل الطلب',
  'Users & report access': 'المستخدمون وصلاحيات التقارير',
  'Sign out': 'تسجيل الخروج',
  'All branches': 'كل الفروع',
  'Branch': 'الفرع',
  'No branches assigned': 'مفيش فروع معيّنة للحساب ده',
  'Refresh': 'تحديث',
  'No data in this period': 'مفيش بيانات في الفترة دي',
  'No open orders': 'مفيش طلبات مفتوحة',
  'Lines': 'الأسطر',
  'Payments': 'المدفوعات',
  'Discount': 'الخصم',
  'Total': 'الإجمالي',
  'Table': 'طاولة',
  'Cashier': 'الكاشير',
  'State': 'الحالة',
  'Save': 'حفظ',
  'Cancel': 'إلغاء',
  'Report access': 'صلاحيات التقارير',
  'Saved': 'تم الحفظ',
  'Owner sees everything': 'المالك بيشوف كل حاجة',
  'Try again': 'حاول مرة أخرى',
  'Loading…': 'جاري التحميل…',
  'Export PDF': 'تصدير PDF',
  'Sales trend': 'اتجاه المبيعات',
  'By order type': 'حسب نوع الطلب',
  'By payment': 'حسب الدفع',
  'Top items': 'أعلى الأصناف',
  'Home': 'الرئيسية',
  'Sales': 'المبيعات',
  'More': 'المزيد',
};
