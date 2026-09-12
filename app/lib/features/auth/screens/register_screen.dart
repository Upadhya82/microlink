import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/validators.dart';
import 'package:flutter/material.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();

  // Basic controllers
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  // Role-specific controller
  String _selectedRole = 'customer'; // Default role

  // Delivery Agent additional fields
  final _vehicleTypeController = TextEditingController();
  final _licensePlateController = TextEditingController();

  // Dummy file names to simulate document uploads.
  // TODO: replace _pickDocument() with the real `file_picker` package
  // (now added to pubspec.yaml) so these hold real picked files, not
  // hardcoded strings.
  String? _idPhotoName;
  String? _businessRegName;
  String? _licensePhotoName;
  String? _policeReportName;

  bool _isLoading = false;

  // Submit form data through the API Gateway -> user-service
  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    // Check if required files are attached
    if (_selectedRole == 'shop_owner' && (_idPhotoName == null || _businessRegName == null)) {
      _showSnackBar('Please upload your ID Photo and Business Registration (BR) Document.');
      return;
    }
    if (_selectedRole == 'delivery_agent' &&
        (_licensePhotoName == null || _policeReportName == null || _idPhotoName == null)) {
      _showSnackBar('Please upload all required driver documents including your Police Report.');
      return;
    }

    setState(() => _isLoading = true);

    // Construct JSON Request Payload according to the user-service API contract
    final Map<String, dynamic> requestPayload = {
      "name": _nameController.text.trim(),
      "email": _emailController.text.trim(),
      "phone": _phoneController.text.trim(),
      "password": _passwordController.text, // Hashed on the backend with bcrypt
      "role": _selectedRole,
    };

    // Append role-specific fields
    if (_selectedRole == 'delivery_agent') {
      requestPayload['delivery_details'] = {
        "vehicle_type": _vehicleTypeController.text.trim(),
        "license_plate": _licensePlateController.text.trim(),
        "driver_license_url": _licensePhotoName, // Sent as file reference name for MVP
        "police_report_url": _policeReportName,
        "id_url": _idPhotoName,
      };
    } else if (_selectedRole == 'shop_owner') {
      requestPayload['shop_details'] = {
        "business_registration_url": _businessRegName,
        "id_url": _idPhotoName,
      };
    }

    try {
      final response = await ApiClient.instance.post(
        '${AppConstants.usersPath}/register',
        data: requestPayload,
      );

      if (response.statusCode == 201) {
        _showSuccessDialog();
      } else {
        final errorData = response.data;
        final detail = errorData is Map ? errorData['detail'] : null;
        _showSnackBar(detail ?? 'Registration failed.');
      }
    } catch (e) {
      _showSnackBar('Unable to connect to the server. Please check if the backend (API Gateway) is running!');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Registration Successful!'),
          content: Text(
            _selectedRole == 'customer'
                ? 'Your account has been registered successfully. Please verify your OTP to log in.'
                : 'Your profile has been created. Since you registered as a $_selectedRole, your documents are pending Admin Verification. We will notify you once approved.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // close dialog
                Navigator.of(context).pop(); // back to Login screen
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // Simulated Document Picker (TODO: replace with the real file_picker package)
  void _pickDocument(String docType) {
    setState(() {
      switch (docType) {
        case 'id':
          _idPhotoName = 'national_id_card.png';
          break;
        case 'br':
          _businessRegName = 'business_registration.pdf';
          break;
        case 'license':
          _licensePhotoName = 'driver_license.png';
          break;
        case 'police':
          _policeReportName = 'police_clearance_cert.pdf';
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Join MicroLink',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),

                      // Name Field
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Full Name',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => Validators.required(v, fieldName: 'Name'),
                      ),
                      const SizedBox(height: 12),

                      // Email Field
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email Address',
                          prefixIcon: Icon(Icons.email),
                          border: OutlineInputBorder(),
                        ),
                        validator: Validators.email,
                      ),
                      const SizedBox(height: 12),

                      // Phone Field
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone Number',
                          prefixIcon: Icon(Icons.phone),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => Validators.required(v, fieldName: 'Phone number'),
                      ),
                      const SizedBox(height: 12),

                      // Password Field (Validates against strong password requirements)
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                          helperText: 'Must be 8+ chars with at least 1 uppercase letter and 1 number',
                          helperMaxLines: 2,
                          border: OutlineInputBorder(),
                        ),
                        validator: Validators.password,
                      ),
                      const SizedBox(height: 16),

                      // Role Selector Dropdown
                      DropdownButtonFormField<String>(
                        initialValue: _selectedRole,
                        decoration: const InputDecoration(
                          labelText: 'Register As',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'customer', child: Text('Customer')),
                          DropdownMenuItem(value: 'shop_owner', child: Text('Shop Owner')),
                          DropdownMenuItem(value: 'delivery_agent', child: Text('Delivery Agent')),
                        ],
                        onChanged: (v) => setState(() => _selectedRole = v!),
                      ),
                      const SizedBox(height: 20),

                      // Dynamic Fields for Shop Owners
                      if (_selectedRole == 'shop_owner') ...[
                        const Divider(),
                        const Text(
                          'Business Documents Verification',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 10),
                        _buildUploadButton('Upload National ID', _idPhotoName, () => _pickDocument('id')),
                        _buildUploadButton('Upload Business Reg (BR)', _businessRegName, () => _pickDocument('br')),
                      ],

                      // Dynamic Fields for Delivery Agents
                      if (_selectedRole == 'delivery_agent') ...[
                        const Divider(),
                        const Text(
                          'Delivery Driver Verification',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 10),

                        // Vehicle Type
                        TextFormField(
                          controller: _vehicleTypeController,
                          decoration: const InputDecoration(
                            labelText: 'Vehicle Type (e.g., Bike, Tuk-Tuk)',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) => Validators.required(v, fieldName: 'Vehicle type'),
                        ),
                        const SizedBox(height: 12),

                        // License Plate Number
                        TextFormField(
                          controller: _licensePlateController,
                          decoration: const InputDecoration(
                            labelText: 'License Plate Number',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) => Validators.required(v, fieldName: 'License plate'),
                        ),
                        const SizedBox(height: 12),

                        _buildUploadButton('Upload National ID', _idPhotoName, () => _pickDocument('id')),
                        _buildUploadButton('Upload Driver\'s License', _licensePhotoName, () => _pickDocument('license')),
                        _buildUploadButton('Upload Police Clearance Report', _policeReportName, () => _pickDocument('police')),
                      ],

                      const SizedBox(height: 24),

                      // Submit Button
                      ElevatedButton(
                        onPressed: _submitRegistration,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text('Register Account', style: TextStyle(fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildUploadButton(String label, String? fileName, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              fileName ?? 'No file uploaded',
              style: TextStyle(color: fileName != null ? Colors.green : Colors.grey, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ElevatedButton.icon(
            onPressed: onPressed,
            icon: Icon(fileName != null ? Icons.check_circle : Icons.upload_file),
            label: Text(label),
            style: ElevatedButton.styleFrom(
              backgroundColor: fileName != null ? Colors.green.shade50 : null,
              foregroundColor: fileName != null ? Colors.green : null,
            ),
          ),
        ],
      ),
    );
  }
}
