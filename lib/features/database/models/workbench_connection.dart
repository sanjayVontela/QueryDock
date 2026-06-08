import 'package:flutter/material.dart';

import '../contracts/database_driver.dart';
import 'database_schema.dart';

class WorkbenchConnection {
  DatabaseProfile profile;
  final DatabaseDriver driver;
  DatabaseSession? session;
  List<DatabaseSchema> schemas;
  bool isConnecting;
  String? error;

  WorkbenchConnection({
    required this.profile,
    required this.driver,
    this.session,
    this.schemas = const [],
    this.isConnecting = false,
    this.error,
  });

  String get id => '${profile.engine.name}:${profile.id}';
  bool get connected => session != null;
  DatabaseCapabilities get capabilities => driver.capabilities;
}

class WorkbenchTableTab<F> {
  static const pageSize = 500;

  final DatabaseSession session;
  final String schema;
  final DatabaseTable metadata;
  final TextEditingController filterController = TextEditingController();
  String innerTab;
  String? sortColumn;
  bool sortAscending;
  final Map<String, F> columnFilters;
  final Map<int, Map<int, String>> pendingChanges;
  List<String> resultColumns;
  List<List<dynamic>> rows;
  bool hasMoreRows;
  bool loadingPage;

  WorkbenchTableTab({
    required this.session,
    required this.schema,
    required this.metadata,
    this.innerTab = 'Data',
    this.sortColumn,
    this.sortAscending = true,
    Map<String, F>? columnFilters,
    Map<int, Map<int, String>>? pendingChanges,
    this.resultColumns = const [],
    this.rows = const [],
    this.hasMoreRows = true,
    this.loadingPage = false,
  }) : columnFilters = columnFilters ?? <String, F>{},
       pendingChanges = pendingChanges ?? <int, Map<int, String>>{};

  String get table => metadata.name;
  String get id => '${profile.engine.name}:${profile.id}:$schema.$table';
  DatabaseProfile get profile => session.profile;
  List<DatabaseColumn> get columns => metadata.columns;
  String get ddl => metadata.ddl;
  List<DatabaseColumn> get primaryKeyColumns =>
      metadata.columns.where((column) => column.primaryKey).toList();
  bool get canEdit =>
      session.capabilities.tableEditing &&
      primaryKeyColumns.isNotEmpty &&
      primaryKeyColumns.every((column) => resultColumns.contains(column.name));

  void dispose() {
    filterController.dispose();
  }
}
