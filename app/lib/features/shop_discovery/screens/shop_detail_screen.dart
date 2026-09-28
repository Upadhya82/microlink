import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/api_client.dart';

class ShopDetailScreen extends StatefulWidget {
  final String? shopId;
  const ShopDetailScreen({super.key, this.shopId});

  @override
  State<ShopDetailScreen> createState() => _ShopDetailScreenState();
}

class _ShopDetailScreenState extends State<ShopDetailScreen> {
  Map<String, dynamic>? _shop;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    if (widget.shopId != null) {
      _loadShop();
    } else {
      _isLoading = false;
    }
  }

  Future<void> _loadShop() async {
    try {
      final response = await ApiClient.instance.get('${AppConstants.shopsPath}/${widget.shopId}');
      setState(() => _shop = response.data as Map<String, dynamic>?);
    } catch (_) {
      // TODO: show a proper error state
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_shop?['name']?.toString() ?? 'Shop Details')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _shop == null
              ? const Center(child: Text('Shop details not available yet.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(_shop!['name']?.toString() ?? '', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_shop!['address']?.toString() ?? 'No address on file'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(_shop!['is_open'] == true ? Icons.check_circle : Icons.cancel,
                            color: _shop!['is_open'] == true ? Colors.green : Colors.red),
                        const SizedBox(width: 6),
                        Text(_shop!['is_open'] == true ? 'Open now' : 'Closed'),
                        const Spacer(),
                        const Icon(Icons.star, color: Colors.amber),
                        Text(' ${_shop!['trust_score'] ?? '-'} / 5'),
                      ],
                    ),
                    // TODO: photos carousel, product availability list,
                    // "View Route to Shop" button -> AppRoutes.liveMap,
                    // reviews + submit-feedback (crowdsource-service).
                  ],
                ),
    );
  }
}

