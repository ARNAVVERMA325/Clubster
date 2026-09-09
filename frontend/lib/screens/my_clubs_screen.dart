import 'package:flutter/material.dart';

/// TODO: list of clubs the signed-in user belongs to. Placeholder only.
class MyClubsScreen extends StatelessWidget {
  const MyClubsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Clubs')),
      body: const Center(child: Text('My Clubs — placeholder')),
    );
  }
}
