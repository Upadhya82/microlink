class Validators {
  Validators._();

  static final _emailPattern = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');

  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) return 'Email is required';
    if (!_emailPattern.hasMatch(value.trim())) return 'Enter a valid email address';
    return null;
  }

  static String? password(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Password must be at least 8 characters';
    return null;
  }

  static String? required(String? value, {String field = 'This field'}) {
    if (value == null || value.trim().isEmpty) return '$field is required';
    return null;
  }

  static String? Function(String?) minLength(int length, {String field = 'This field'}) {
    return (value) {
      if (value == null || value.trim().length < length) {
        return '$field must be at least $length characters';
      }
      return null;
    };
  }

  static String? phone(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    // Sri Lankan mobile numbers are ten digits, written 07X XXX XXXX. Saying
    // how many are expected is more use than "invalid".
    if (digits.length != 10) return 'Phone number must be 10 digits';
    return null;
  }

  static String? positiveNumber(String? value, {String field = 'Value'}) {
    if (value == null || value.trim().isEmpty) return '$field is required';
    final parsed = double.tryParse(value);
    if (parsed == null || parsed <= 0) return '$field must be a positive number';
    return null;
  }
}
