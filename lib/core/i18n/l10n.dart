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
  // sell / catalogue
  'Send to kitchen': 'إرسال للمطبخ',
  'Sent to kitchen.': 'أُرسل للمطبخ.',
  'Pay': 'دفع',
  'None': 'بدون',
  'Max': 'الحد الأقصى',
  'Capped at': 'الحد الأقصى',
  'Sold out': 'نفد',
  'Mark sold out': 'وضع كنافد',
  'Mark available': 'إتاحة',
  'Add favourite': 'إضافة للمفضلة',
  'Remove favourite': 'إزالة من المفضلة',
  'Favourites': 'المفضلة',
  'available': 'متاح',
  'sold out': 'نفد',
  'Tax (incl.)': 'الضريبة (شاملة)',
  'Weight for': 'وزن',
  'Weight': 'الوزن',
  // settings hub titles + subtitles
  'Grid density': 'كثافة الشبكة',
  'Customers': 'العملاء',
  'Tiles per row': 'مربعات في الصف',
  'Auto (fit width)': 'تلقائي',
  'Name, tax id, footer': 'الاسم، الرقم الضريبي، التذييل',
  'Header, footer, what prints': 'الترويسة، التذييل، ما يُطبع',
  'Percentages, cap, reasons': 'النسب، الحد، الأسباب',
  'Where sales sync at shift close': 'أين تتزامن المبيعات عند إغلاق الوردية',
  'Add / search till customers': 'إضافة / بحث عملاء الكاشير',
  // discounts settings
  'Quick discount percentages': 'نسب الخصم السريعة',
  'Add percentage': 'إضافة نسبة',
  'Maximum discount': 'أقصى خصم',
  'Cap (blank = none)': 'الحد (فارغ = بلا)',
  'Add reason': 'إضافة سبب',
  // roster
  'Show inactive': 'إظهار غير النشط',
  'inactive': 'غير نشط',
  'Reactivate': 'إعادة تفعيل',
  'Deactivate': 'إلغاء التفعيل',
  'Manager': 'مدير',
  'Cashier': 'كاشير',
  // tables
  'Rename section': 'إعادة تسمية القسم',
  'Delete section and its tables': 'حذف القسم وطاولاته',
  'No tables yet': 'لا توجد طاولات بعد',
  'Set up the floor': 'إعداد الصالة',
  'New section': 'قسم جديد',
  // reports
  'Sales report': 'تقرير المبيعات',
  'Overview': 'نظرة عامة',
  'Orders': 'الطلبات',
  'Gross sales': 'إجمالي المبيعات',
  'Discounts given': 'الخصومات الممنوحة',
  'Delivery income': 'دخل التوصيل',
  'Tips': 'الإكراميات',
  'Payment mix': 'توزيع الدفع',
  'Item sales': 'مبيعات الأصناف',
  'By reason': 'حسب السبب',
  'How customers paid': 'كيف دفع العملاء',
  'Grand total': 'الإجمالي الكلي',
  'By hour': 'حسب الساعة',
  'By revenue': 'حسب الإيراد',
  'By quantity': 'حسب الكمية',
  'Total sales': 'إجمالي المبيعات',
  'Avg order': 'متوسط الطلب',
  'Overall': 'الإجمالي',
  'Print summary': 'طباعة الملخص',
  'Summary sent to printer': 'أُرسل الملخص للطابعة',
  'Custom': 'مخصص',
  // shift
  'Open since': 'مفتوحة منذ',
  'No shift is open': 'لا توجد وردية مفتوحة',
  'Opening float': 'الرصيد الافتتاحي',
  'Sales': 'المبيعات',
  'Cash sales': 'المبيعات النقدية',
  'Expected in drawer': 'المتوقع في الدرج',
  'Cash movements': 'حركات النقد',
  'In': 'إيداع',
  'Out': 'سحب',
  'Amount': 'المبلغ',
  'Reason (optional)': 'السبب (اختياري)',
  'Close shift': 'إغلاق الوردية',
  'Expected': 'المتوقع',
  'Counted': 'المحسوب',
  'Print X read': 'طباعة قراءة X',
  'Print': 'طباعة',
  // reprint / receipt designer
  'Print test receipt': 'طباعة إيصال تجريبي',
  'Test receipt sent to printer': 'أُرسل الإيصال التجريبي للطابعة',
  // dine-in: split / move / merge
  'Split / move': 'تقسيم / نقل',
  'Assign to guest': 'إسناد لضيف',
  'Guest': 'ضيف',
  'Guest number': 'رقم الضيف',
  'Clear': 'مسح',
  'Split by guest': 'تقسيم على الضيوف',
  'Pay each guest separately': 'ادفع لكل ضيف على حدة',
  'Pay selected items': 'دفع الأصناف المحددة',
  'Move items to another table': 'نقل الأصناف لطاولة أخرى',
  'Merge another table in': 'دمج طاولة أخرى',
  'Shared': 'مشترك',
  'Check': 'حساب',
  'Rest of the table stays open.': 'يبقى باقي الطاولة مفتوحاً.',
  'Table closed.': 'أُغلقت الطاولة.',
  'Choose table': 'اختر طاولة',
  'Destination table': 'الطاولة الوجهة',
  'item(s) moved to table': 'صنف/أصناف نُقلت للطاولة',
  'No other open tables to merge': 'لا توجد طاولات مفتوحة أخرى للدمج',
  'Tables merged': 'تم دمج الطاولات',
  'Tab': 'حساب',
  'item(s)': 'صنف/أصناف',
  // audit log
  'Audit log': 'سجل التدقيق',
  'Export CSV': 'تصدير CSV',
  'Audit log copied as CSV': 'تم نسخ سجل التدقيق كملف CSV',
  'All events': 'كل الأحداث',
  'No audit entries': 'لا توجد قيود تدقيق',
  'Actor': 'المستخدم',
  'Event': 'الحدث',
  // activity report
  'Cancelled, voided & refunded': 'إلغاء، إفراغ واسترجاع',
  'Refunds': 'المرتجعات',
  'Voided lines': 'الأصناف المُفرغة',
  'Cancelled orders': 'الطلبات الملغاة',
  'No refunds': 'لا توجد مرتجعات',
  'No voided lines': 'لا توجد أصناف مُفرغة',
  'No cancelled orders': 'لا توجد طلبات ملغاة',
  'Total refunded': 'إجمالي المرتجع',
  'No reason': 'بدون سبب',
  // expenses (shift paid-out categories)
  'Category': 'الفئة',
  'Transport': 'مواصلات',
  'Food': 'طعام',
  'Supplies': 'مستلزمات',
  'Maintenance': 'صيانة',
  'Other': 'أخرى',
  // resend to kitchen
  'Resend to kitchen': 'إعادة الإرسال للمطبخ',
  'Resend': 'إعادة إرسال',
  'Print the whole ticket again?': 'طباعة التذكرة كاملة من جديد؟',
  // attendance
  'Attendance': 'الحضور',
  'No staff yet': 'لا يوجد موظفون بعد',
  'on the clock': 'على رأس العمل',
  'Since': 'منذ',
  'Off the clock': 'خارج الدوام',
  'Clock in': 'تسجيل حضور',
  'Clock out': 'تسجيل انصراف',
  // status colours / dine-in visuals
  'Sent': 'أُرسل',
  'All sent': 'تم إرسال الكل',
  'free': 'مجاني',
  'New items': 'أصناف جديدة',
  'Held': 'معلّق',
  'Choose a table': 'اختر طاولة',
  'Other / custom': 'أخرى / مخصص',
  'This table': 'هذه الطاولة',
  'No tables yet. Add them in Settings.': 'لا توجد طاولات بعد. أضِفها من الإعدادات.',
  // printers & receipt
  'Receipt & paper': 'الإيصال والورق',
  'Paper width': 'عرض الورق',
  'Copies': 'عدد النسخ',
  'Open cash drawer on cash sale': 'فتح درج النقود عند البيع النقدي',
  'Not found': 'غير موجودة',
  'Test print': 'طباعة تجريبية',
  'test receipt sent': 'أُرسل الإيصال التجريبي',
  'not reachable': 'غير قابلة للوصول',
  'Split into single items': 'تقسيم إلى أصناف مفردة',
  'So you can change one on its own': 'حتى تُعدّل واحداً بمفرده',
};
