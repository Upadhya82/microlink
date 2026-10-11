import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI language support (REQ-PERS-1).
///
/// English and Sinhala ship. The SRS also lists Tamil; it was dropped from
/// this build on the team's instruction, so adding it later means adding a
/// `'ta'` block below and one entry in [AppLanguage.supported] -- nothing
/// else in the app needs to change.
///
/// A hand-rolled lookup rather than Flutter's `gen_l10n`: the generated
/// approach needs a build step and an .arb file per language, and the team
/// adds strings constantly. Here a new string is one line in each map, and a
/// key with no translation falls back to English rather than showing the raw
/// key to the user.
///
/// Scope note: the screens the SRS calls out for language support are
/// translated (settings, auth, notifications, navigation, delivery basics).
/// The rest stay English until someone supplies the wording -- see
/// [missingKeysFor] which exists to make that gap measurable rather than
/// invisible.
class AppLanguage {
  final String code;
  final String englishName;

  /// The name written in the language itself, which is what people scan for
  /// in a language list.
  final String nativeName;

  const AppLanguage(this.code, this.englishName, this.nativeName);

  static const english = AppLanguage('en', 'English', 'English');
  static const sinhala = AppLanguage('si', 'Sinhala', 'සිංහල');

  static const List<AppLanguage> supported = [english, sinhala];

  static AppLanguage byCode(String code) {
    return supported.firstWhere(
      (l) => l.code == code,
      orElse: () => english,
    );
  }
}

/// Holds the chosen language and notifies the app to rebuild on change.
class LanguageController extends ChangeNotifier {
  LanguageController._();
  static final LanguageController instance = LanguageController._();

  static const String _key = 'microlink_language';

  AppLanguage _language = AppLanguage.english;
  bool _loaded = false;

  AppLanguage get language => _language;
  String get code => _language.code;

  Future<void> loadFromDisk() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved != null) {
        _language = AppLanguage.byCode(saved);
        notifyListeners();
      }
    } catch (_) {
      // Unreadable preference just means English.
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language.code == language.code) return;
    _language = language;
    // Notify first: the UI should switch instantly (REQ-PERS-1 says without
    // an app restart), not after the disk write returns.
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, language.code);
    } catch (_) {
      // Keeping it for this session is better than refusing the change.
    }
  }
}

/// Look up [key] in the current language, falling back to English.
String tr(String key) {
  final code = LanguageController.instance.code;
  if (code != 'en') {
    final translated = _translations[code]?[key];
    if (translated != null) return translated;
  }
  return _translations['en']?[key] ?? key;
}

/// Keys that have no translation in [code]. Used by the settings screen to
/// tell the user honestly how complete a language is, instead of letting
/// them discover half-English screens by surprise.
List<String> missingKeysFor(String code) {
  if (code == 'en') return const [];
  final target = _translations[code] ?? const {};
  return _translations['en']!.keys.where((k) => !target.containsKey(k)).toList();
}

/// Percentage of the string table translated into [code], 0-100.
int translationCoverage(String code) {
  if (code == 'en') return 100;
  final total = _translations['en']!.length;
  if (total == 0) return 100;
  return (((total - missingKeysFor(code).length) / total) * 100).round();
}

const Map<String, Map<String, String>> _translations = {
  'en': {
    // --- common
    'app.name': 'MicroLink',
    'common.cancel': 'Cancel',
    'common.save': 'Save',
    'common.retry': 'Retry',
    'common.close': 'Close',
    'common.search': 'Search',
    'common.loading': 'Loading…',
    'common.open_now': 'Open now',
    'common.closed': 'Closed',
    'common.km_away': 'km away',

    // --- auth
    'auth.welcome_back': 'Welcome back! Log in to continue.',
    'auth.email': 'Email',
    'auth.password': 'Password',
    'auth.login': 'Log In',
    'auth.logout': 'Log Out',
    'auth.no_account': "Don't have an account?",
    'auth.sign_up': 'Sign up',
    'auth.full_name': 'Full name',
    'auth.register': 'Create account',
    'auth.continue_as_guest': 'Continue as guest',

    // --- settings
    'settings.title': 'Settings',
    'settings.language': 'Language',
    'settings.language_subtitle': 'Choose the language for the app',
    'settings.theme': 'Appearance',
    'settings.dark_mode': 'Dark mode',
    'settings.dark_mode_subtitle': 'Easier on the eyes at night',
    'settings.about': 'About MicroLink',
    'settings.about_subtitle': 'Version, team and what this app does',
    'settings.partially_translated': 'This language is partly translated. '
        'Untranslated text stays in English.',

    // --- about
    'about.title': 'About MicroLink',
    'about.tagline':
        'Find, reach and get deliveries from the small businesses around you.',
    'about.what_it_does': 'What it does',
    'about.version': 'Version',
    'about.team': 'Project team',

    // --- notifications
    'notifications.title': 'Notifications',
    'notifications.mark_all_read': 'Mark all read',
    'notifications.empty_title': 'No notifications yet',
    'notifications.empty_body':
        'Updates about your orders, shops and reports will show up here.',

    // --- navigation
    'nav.title': 'Live Map',
    'nav.search_area': 'Search any area in Sri Lanka',
    'nav.search_this_area': 'Search this area',
    'nav.my_deliveries': 'My deliveries',
    'nav.driving': 'Driving',
    'nav.walking': 'Walking',
    'nav.cycling': 'Cycling',
    'nav.fastest': 'Fastest',
    'nav.shortest': 'Shortest',
    'nav.voice_on': 'Voice on',
    'nav.voice_off': 'Voice off',
    'nav.delivery_to': 'Delivery to',
    'nav.centre_on_me': 'Centre on me',

    // --- delivery
    'delivery.checkout': 'Checkout',
    'delivery.deliver_to': 'Deliver to',
    'delivery.place_order': 'Place order',
    'delivery.pick_on_map': 'Pick on map',
    'delivery.use_my_location': 'Use my location',
    'delivery.no_location': 'No delivery location chosen yet',
    'delivery.my_orders': 'My Orders',
      'home.explore': 'Explore',
    'home.greeting': 'Hi',
    'home.search_hint': 'Search shops or essential items…',
    'home.recommended': 'Recommended for You',
    'home.recommended_sub': 'Personalised from what you browse, favourite & prefer',
    'home.nearby_shops': 'Nearby Shops',
    'home.on_the_map': 'On the Map',
    'home.contributions': 'Your Contributions',
    'home.see_all': 'See all',
    'home.view_all': 'View All',
    'home.view_map': 'View Map',
    'nav.home': 'Home',
    'nav.map': 'Map',
    'nav.search': 'Search',
    'nav.profile': 'Profile',
    'nav.account': 'Account',
    'category.grocery': 'Grocery',
    'category.restaurant': 'Restaurant',
    'category.pharmacy': 'Pharmacy',
    'category.electronics': 'Electronics',
    'category.clothing': 'Clothing',
    'category.hardware': 'Hardware',
    'category.stationery': 'Stationery',
    'category.bakery': 'Bakery',
    'category.other': 'Other',
    'shops.title': 'Discover Shops',
    'shops.search_hint': 'Search shops',
    'shops.near_landmark': 'Search near a landmark',
    'shops.none_title': 'No shops found',
    'shops.none_body': 'Try a different search, or widen the radius in the filters.',
    'shops.all': 'All',
    'shops.directions': 'Directions',
    'shops.rate': 'Rate shop',
    'shops.products': 'Products',
    'shops.reviews': 'Ratings & reviews',
    'shops.no_reviews': 'No reviews yet.',
    'shops.in_stock': 'In stock',
    'shops.low_stock': 'Low stock',
    'shops.out_of_stock': 'Out of stock',
    'orders.my_orders': 'My Orders',
    'orders.none_title': 'No orders yet',
    'orders.none_body': 'Orders you place with shops will show up here.',
    'orders.tracking': 'Order Tracking',
    'orders.cart': 'View cart',
    'orders.add_to_cart': 'Add to cart',
    'orders.you_save': 'You save',
    'orders.pickup_code': 'Pickup code',
    'orders.delivery_code': 'Delivery code',
    'common.items': 'items',
    'common.item': 'item',
    'common.delivery': 'Delivery',
    'common.verified': 'Verified',
},
  'si': {
    'app.name': 'මයික්‍රෝලින්ක්',
    'common.cancel': 'අවලංගු කරන්න',
    'common.save': 'සුරකින්න',
    'common.retry': 'නැවත උත්සාහ කරන්න',
    'common.close': 'වසන්න',
    'common.search': 'සොයන්න',
    'common.loading': 'පූරණය වෙමින්…',
    'common.open_now': 'දැන් විවෘතයි',
    'common.closed': 'වසා ඇත',
    'common.km_away': 'කි.මී. දුරින්',

    'auth.welcome_back': 'නැවත පිළිගනිමු! ඉදිරියට යාමට පිවිසෙන්න.',
    'auth.email': 'විද්‍යුත් තැපෑල',
    'auth.password': 'මුරපදය',
    'auth.login': 'පිවිසෙන්න',
    'auth.logout': 'පිටවෙන්න',
    'auth.no_account': 'ගිණුමක් නැද්ද?',
    'auth.sign_up': 'ලියාපදිංචි වන්න',
    'auth.full_name': 'සම්පූර්ණ නම',
    'auth.register': 'ගිණුම සාදන්න',
    'auth.continue_as_guest': 'අමුත්තෙකු ලෙස ඉදිරියට',

    'settings.title': 'සැකසුම්',
    'settings.language': 'භාෂාව',
    'settings.language_subtitle': 'යෙදුම සඳහා භාෂාව තෝරන්න',
    'settings.theme': 'පෙනුම',
    'settings.dark_mode': 'අඳුරු මාදිලිය',
    'settings.dark_mode_subtitle': 'රාත්‍රියේ ඇසට සැහැල්ලුයි',
    'settings.about': 'මයික්‍රෝලින්ක් ගැන',
    'settings.about_subtitle': 'අනුවාදය, කණ්ඩායම සහ යෙදුම ගැන',
    'settings.partially_translated':
        'මෙම භාෂාව අර්ධ වශයෙන් පරිවර්තනය කර ඇත. පරිවර්තනය නොකළ කොටස් ඉංග්‍රීසියෙන් පෙනේ.',

    'about.title': 'මයික්‍රෝලින්ක් ගැන',
    'about.tagline': 'ඔබ අවට කුඩා ව්‍යාපාර සොයා ගන්න, ළඟා වන්න සහ බෙදාහැරීම් ලබා ගන්න.',
    'about.what_it_does': 'යෙදුම කරන්නේ කුමක්ද',
    'about.version': 'අනුවාදය',
    'about.team': 'ව්‍යාපෘති කණ්ඩායම',

    'notifications.title': 'දැනුම්දීම්',
    'notifications.mark_all_read': 'සියල්ල කියවූ ලෙස සලකුණු කරන්න',
    'notifications.empty_title': 'තවම දැනුම්දීම් නැත',
    'notifications.empty_body':
        'ඔබේ ඇණවුම්, වෙළඳසැල් සහ වාර්තා පිළිබඳ යාවත්කාලීන මෙහි පෙන්වයි.',

    'nav.title': 'සජීවී සිතියම',
    'nav.search_area': 'ශ්‍රී ලංකාවේ ඕනෑම ප්‍රදේශයක් සොයන්න',
    'nav.search_this_area': 'මෙම ප්‍රදේශය සොයන්න',
    'nav.my_deliveries': 'මගේ බෙදාහැරීම්',
    'nav.driving': 'රිය පැදවීම',
    'nav.walking': 'ඇවිදීම',
    'nav.cycling': 'බයිසිකලය',
    'nav.fastest': 'වේගවත්ම',
    'nav.shortest': 'කෙටිම',
    'nav.voice_on': 'හඬ ක්‍රියාත්මකයි',
    'nav.voice_off': 'හඬ නිශ්ශබ්දයි',
    'nav.delivery_to': 'බෙදාහරින ස්ථානය',
    'nav.centre_on_me': 'මා වෙත යොමු කරන්න',

    'delivery.checkout': 'ඇණවුම සම්පූර්ණ කරන්න',
    'delivery.deliver_to': 'බෙදාහරින ස්ථානය',
    'delivery.place_order': 'ඇණවුම තබන්න',
    'delivery.pick_on_map': 'සිතියමේ තෝරන්න',
    'delivery.use_my_location': 'මගේ ස්ථානය භාවිතා කරන්න',
    'delivery.no_location': 'තවම බෙදාහරින ස්ථානයක් තෝරා නැත',
    'delivery.my_orders': 'මගේ ඇණවුම්',
      'home.explore': 'ගවේෂණය',
    'home.greeting': 'ආයුබෝවන්',
    'home.search_hint': 'වෙළඳසැල් හෝ අත්‍යවශ්‍ය භාණ්ඩ සොයන්න…',
    'home.recommended': 'ඔබට නිර්දේශිතයි',
    'home.recommended_sub': 'ඔබ බලන, කැමති සහ තෝරන දේ අනුව',
    'home.nearby_shops': 'අවට වෙළඳසැල්',
    'home.on_the_map': 'සිතියමේ',
    'home.contributions': 'ඔබේ දායකත්වය',
    'home.see_all': 'සියල්ල බලන්න',
    'home.view_all': 'සියල්ල බලන්න',
    'home.view_map': 'සිතියම බලන්න',
    'nav.home': 'මුල් පිටුව',
    'nav.map': 'සිතියම',
    'nav.search': 'සෙවීම',
    'nav.profile': 'පැතිකඩ',
    'nav.account': 'ගිණුම',
    'category.grocery': 'සිල්ලර',
    'category.restaurant': 'අවන්හල',
    'category.pharmacy': 'ෆාමසිය',
    'category.electronics': 'ඉලෙක්ට්‍රොනික',
    'category.clothing': 'ඇඳුම්',
    'category.hardware': 'දෘඩ භාණ්ඩ',
    'category.stationery': 'ලිපි ද්‍රව්‍ය',
    'category.bakery': 'බේකරිය',
    'category.other': 'වෙනත්',
    'shops.title': 'වෙළඳසැල් සොයන්න',
    'shops.search_hint': 'වෙළඳසැල් සොයන්න',
    'shops.near_landmark': 'සලකුණක් අසල සොයන්න',
    'shops.none_title': 'වෙළඳසැල් හමු නොවීය',
    'shops.none_body': 'වෙනත් සෙවීමක් කරන්න, නැතහොත් පෙරහන්වල පරාසය වැඩි කරන්න.',
    'shops.all': 'සියල්ල',
    'shops.directions': 'මාර්ග උපදෙස්',
    'shops.rate': 'වෙළඳසැල ශ්‍රේණිගත කරන්න',
    'shops.products': 'නිෂ්පාදන',
    'shops.reviews': 'ශ්‍රේණිගත කිරීම් සහ සමාලෝචන',
    'shops.no_reviews': 'තවම සමාලෝචන නැත.',
    'shops.in_stock': 'තොගයේ ඇත',
    'shops.low_stock': 'තොගය අඩුයි',
    'shops.out_of_stock': 'තොගය නැත',
    'orders.my_orders': 'මගේ ඇණවුම්',
    'orders.none_title': 'තවම ඇණවුම් නැත',
    'orders.none_body': 'ඔබ කරන ඇණවුම් මෙහි පෙන්වයි.',
    'orders.tracking': 'ඇණවුම් නිරීක්ෂණය',
    'orders.cart': 'කරත්තය බලන්න',
    'orders.add_to_cart': 'කරත්තයට එක් කරන්න',
    'orders.you_save': 'ඔබ ඉතිරි කරයි',
    'orders.pickup_code': 'රැගෙන යාමේ කේතය',
    'orders.delivery_code': 'බෙදාහැරීමේ කේතය',
    'common.items': 'අයිතම',
    'common.item': 'අයිතමය',
    'common.delivery': 'බෙදාහැරීම',
    'common.verified': 'තහවුරු කළ',
},
};
