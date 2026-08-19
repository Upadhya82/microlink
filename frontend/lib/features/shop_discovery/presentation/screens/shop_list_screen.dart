import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/api_client.dart';
import 'shop_detail_screen.dart';

class ShopListScreen extends StatefulWidget {
  const ShopListScreen({super.key});

  @override
  State<ShopListScreen> createState() => _ShopListScreenState();
}

class _ShopListScreenState extends State<ShopListScreen> {
  final _searchController = TextEditingController();
  List<dynamic> _shops = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchShops();
  }

  Future<void> _fetchShops({String? keyword}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await ApiClient.instance.get(
        AppConstants.shopsPath,
        query: keyword != null && keyword.isNotEmpty ? {'q': keyword} : null,
      );
      setState(() => _shops = (response.data as List?) ?? []);
    } catch (e) {
      setState(() => _error = 'Could not load shops. Is shop-service running?');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Shops'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search shops, categories, products...',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _fetchShops(keyword: _searchController.text),
                ),
              ),
              onSubmitted: (v) => _fetchShops(keyword: v),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _shops.isEmpty
                  ? const Center(child: Text('No shops found yet.'))
                  : ListView.builder(
                      itemCount: _shops.length,
                      itemBuilder: (context, i) {
                        final shop = _shops[i] as Map<String, dynamic>;
                        return ListTile(
                          leading: const Icon(Icons.storefront),
                          title: Text(shop['name']?.toString() ?? 'Unnamed shop'),
                          subtitle: Text(shop['category']?.toString() ?? ''),
                          trailing: Text(shop['is_open'] == true ? 'Open' : 'Closed'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ShopDetailScreen(shopId: shop['id']?.toString())),
                          ),
                        );
                      },
                    ),
    );
  }
}

