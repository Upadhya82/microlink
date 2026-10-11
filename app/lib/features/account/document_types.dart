import 'package:flutter/material.dart';

/// One document the backend accepts, with the wording the applicant sees.
class DocType {
  final String value;
  final String label;
  final String help;
  final IconData icon;

  const DocType(this.value, this.label, this.help, this.icon);
}

/// Mirrors DOCUMENT_TYPES in user-service's schemas.py.
const kAllDocTypes = <DocType>[
  DocType('national_id', 'National ID', 'Front side, clearly readable',
      Icons.badge_outlined),
  DocType('business_registration', 'Business registration',
      'Your BR certificate', Icons.description_outlined),
  DocType('driving_licence', 'Driving licence', 'Front side',
      Icons.drive_eta_outlined),
  DocType('police_clearance', 'Police clearance',
      'Police clearance certificate', Icons.verified_user_outlined),
  DocType('vehicle_registration', 'Vehicle registration',
      'Registration book for the vehicle you deliver with',
      Icons.two_wheeler_outlined),
  DocType('profile_photo', 'Profile photo', 'A clear photo of your face',
      Icons.account_circle_outlined),
];

/// What each role is actually asked for. The backend accepts any type from
/// anyone, so this is guidance rather than enforcement -- a shop owner who
/// also delivers can still add a licence from the "other documents" list.
const kRequiredDocsByRole = <String, List<String>>{
  'shop_owner': ['national_id', 'business_registration', 'profile_photo'],
  'delivery_agent': [
    'national_id',
    'driving_licence',
    'police_clearance',
    'vehicle_registration',
    'profile_photo',
  ],
};

DocType docTypeFor(String value) =>
    kAllDocTypes.firstWhere((t) => t.value == value);

/// The human labels for a role's required documents, for screens that only
/// need to say what will be asked for.
List<String> requiredDocLabelsFor(String role) =>
    (kRequiredDocsByRole[role] ?? const <String>[])
        .map((v) => docTypeFor(v).label)
        .toList();
