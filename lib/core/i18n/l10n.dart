import 'package:flutter/widgets.dart';

/// Bilingual English/Arabic support with right-to-left layout.
///
/// Design: the English string IS the key. `tr(context, 'Payment')` returns the
/// Arabic when the app locale is Arabic and a translation exists, otherwise the
/// English source. That keeps call sites readable, needs no code generation, and
/// degrades gracefully: an untranslated string simply shows in English rather than
/// as a raw key. Right-to-left comes for free from MaterialApp's Arabic locale via
/// the Flutter localization delegates.
String tr(BuildContext context, String en) {
  final code = Localizations.localeOf(context).languageCode;
  if (code == 'ar') return _ar[en] ?? en;
  return en;
}

/// Drives the app locale. Held above MaterialApp; changing it rebuilds the app in
/// the new language and text direction, and persists the choice.
class LocaleController extends ValueNotifier<Locale> {
  LocaleController(super.value, {this.onChanged});

  /// Persists the chosen language code ('en'/'ar').
  final void Function(String code)? onChanged;

  bool get isArabic => value.languageCode == 'ar';

  void setLanguage(String code) {
    value = Locale(code);
    onChanged?.call(code);
  }

  void toggle() => setLanguage(isArabic ? 'en' : 'ar');
}

/// The supported locales, in offer order.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('ar')];

/// English source -> Arabic. Covers the daily cashier flow and the common controls;
/// anything absent falls back to English. Kept in one place so translations are
/// reviewed together.
const Map<String, String> _ar = {
  // common actions
  'Cancel': 'إلغاء',
  'Save': 'حفظ',
  'Add': 'إضافة',
  'OK': 'موافق',
  'Set': 'تعيين',
  'Apply': 'تطبيق',
  'Confirm': 'تأكيد',
  'Done': 'تم',
  'Remove': 'حذف',
  'Delete': 'حذف',
  'Edit': 'تعديل',
  'Approve': 'اعتماد',
  'Search': 'بحث',
  'Saved': 'تم الحفظ',
  // selling
  'Search or scan': 'ابحث أو امسح',
  'No products': 'لا توجد منتجات',
  'Start adding products': 'ابدأ بإضافة المنتجات',
  'Payment': 'الدفع',
  'Hold': 'تعليق',
  'TOTAL': 'الإجمالي',
  'Subtotal': 'المجموع الفرعي',
  'Discount': 'خصم',
  'Add discount': 'إضافة خصم',
  'Edit discount': 'تعديل الخصم',
  'Delivery': 'توصيل',
  'Tip': 'إكرامية',
  'Total due': 'المبلغ المستحق',
  'Amount received': 'المبلغ المستلم',
  'Change': 'الباقي',
  'Split': 'تقسيم',
  'Tip (optional)': 'إكرامية (اختياري)',
  'Walk-in customer': 'عميل عابر',
  'Customer': 'العميل',
  'End shift': 'إنهاء الوردية',
  'New order': 'طلب جديد',
  'Open orders': 'الطلبات المفتوحة',
  'Note': 'ملاحظة',
  'Note added': 'تمت إضافة ملاحظة',
  'Order note': 'ملاحظة الطلب',
  'Guests': 'الضيوف',
  'Table': 'طاولة',
  'Note for kitchen': 'ملاحظة للمطبخ',
  'Line discount': 'خصم على الصنف',
  'Void this line': 'إلغاء هذا الصنف',
  'Reason': 'السبب',
  'Manager approval': 'موافقة المدير',
  'Manager PIN': 'رمز المدير',
  'Manager approval failed': 'فشلت موافقة المدير',
  // order types
  'Dine-in': 'صالة',
  'Takeaway': 'سفري',
  // navigation
  'Tables': 'الطاولات',
  'Kitchen display': 'شاشة المطبخ',
  'Reports': 'التقارير',
  'Shift / cash-up': 'الوردية / تقفيل الصندوق',
  'Staff': 'الموظفون',
  'Settings': 'الإعدادات',
  'Support & printers': 'الدعم والطابعات',
  'Order history': 'سجل الطلبات',
  // tables
  'Kitchen': 'المطبخ',
  'No open tables': 'لا توجد طاولات مفتوحة',
  'Occupied': 'مشغولة',
  'Free': 'متاحة',
  'Section': 'قسم',
  'Seats': 'المقاعد',
  // shift
  'Open shift': 'فتح وردية',
  'Close shift (Z)': 'إغلاق الوردية (Z)',
  'Cash in': 'إيداع نقدي',
  'Cash out': 'سحب نقدي',
  'Counted cash': 'النقد المحسوب',
  'Z report': 'تقرير Z',
  'Variance': 'الفرق',
  // auth
  'Incorrect PIN': 'رمز غير صحيح',
  // status
  'Online': 'متصل',
  'Offline': 'غير متصل',
  'Refund': 'استرجاع',
  'Reprint receipt': 'إعادة طباعة الإيصال',
  // settings
  'Shop & receipt': 'المتجر والإيصال',
  'Category colours': 'ألوان الأقسام',
  'Quick notes': 'ملاحظات سريعة',
  'Discount reasons': 'أسباب الخصم',
  'Receipt designer': 'مصمم الإيصال',
  'Printers & kitchen routing': 'الطابعات وتوجيه المطبخ',
  'Printers & routing': 'الطابعات والتوجيه',
  'Server (Odoo)': 'الخادم (أودو)',
  'Server settings': 'إعدادات الخادم',
  'Shop name': 'اسم المتجر',
  'Tax id': 'الرقم الضريبي',
  'Receipt footer': 'تذييل الإيصال',
  'Add staff': 'إضافة موظف',
  'Add printer': 'إضافة طابعة',
  'Add table': 'إضافة طاولة',
  'Name / number': 'الاسم / الرقم',
  // reports
  'Sales summary': 'ملخص المبيعات',
  'Tax': 'الضريبة',
  'Tax report': 'تقرير الضريبة',
  'Top products': 'أفضل المنتجات',
  'Category performance': 'أداء الأقسام',
  'Payment analysis': 'تحليل المدفوعات',
  'Discounts': 'الخصومات',
  'Cashier performance': 'أداء الكاشير',
  'Sales by hour': 'المبيعات بالساعة',
  'Net': 'الصافي',
  'Rate': 'النسبة',
  'Gross': 'الإجمالي',
  'Total': 'الإجمالي',
  'Today': 'اليوم',
  'Yesterday': 'أمس',
  'Last 7 days': 'آخر 7 أيام',
  'All': 'الكل',
  'No orders': 'لا توجد طلبات',
  'No orders yet': 'لا توجد طلبات بعد',
  'No active tickets': 'لا توجد طلبات نشطة',
  // kds statuses
  'New': 'جديد',
  'Preparing': 'قيد التحضير',
  'Ready': 'جاهز',
  'Served': 'تم التقديم',
  'Start': 'ابدأ',
};
