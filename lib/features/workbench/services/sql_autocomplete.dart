import '../../database/models/database_schema.dart';

class SqlCompletion {
  final String label;
  final String detail;
  final String text;
  final int cursorOffset;
  final String? schema;
  final String? table;

  const SqlCompletion({
    required this.label,
    required this.detail,
    required this.text,
    required this.cursorOffset,
    this.schema,
    this.table,
  });
}

class SqlMetadataRequest {
  final String? schema;
  final DatabaseTable? table;

  const SqlMetadataRequest.schema(this.schema) : table = null;

  const SqlMetadataRequest.table(this.schema, this.table);
}

class SqlAutocompleteResult {
  final List<SqlCompletion> options;
  final SqlMetadataRequest? metadataRequest;

  const SqlAutocompleteResult({this.options = const [], this.metadataRequest});
}

class SqlAutocompleteEngine {
  static const _keywords = <String>{
    'SELECT',
    'FROM',
    'WHERE',
    'ORDER BY',
    'GROUP BY',
    'LIMIT',
    'JOIN',
    'LEFT JOIN',
    'INNER JOIN',
    'INSERT',
    'UPDATE',
    'DELETE',
  };

  const SqlAutocompleteEngine();

  SqlAutocompleteResult build({
    required String sql,
    required int cursor,
    required List<DatabaseSchema> schemas,
    int limit = 12,
  }) {
    final safeCursor = cursor.clamp(0, sql.length);
    final textBeforeCursor = sql.substring(0, safeCursor);
    final match = RegExp(
      r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]*)?$',
    ).firstMatch(textBeforeCursor);
    final token = match?.group(0) ?? '';
    if (token.isEmpty) return const SqlAutocompleteResult();

    final tokenStart = match!.start;
    final lowerToken = token.toLowerCase();
    final aliases = aliasesIn(sql);

    if (token.contains('.')) {
      final dotIndex = token.indexOf('.');
      final qualifier = token.substring(0, dotIndex);
      final suffix = token.substring(dotIndex + 1).toLowerCase();
      final schema = schemas
          .where(
            (candidate) =>
                candidate.name.toLowerCase() == qualifier.toLowerCase(),
          )
          .firstOrNull;
      if (schema != null) {
        if (!schema.tablesLoaded) {
          return SqlAutocompleteResult(
            metadataRequest: SqlMetadataRequest.schema(schema.name),
          );
        }
        return SqlAutocompleteResult(
          options: [
            for (final table in schema.tables)
              if (table.name.toLowerCase().startsWith(suffix))
                _tableCompletion(
                  sql: sql,
                  cursor: safeCursor,
                  tokenStart: tokenStart,
                  schema: schema.name,
                  table: table.name,
                  aliases: aliases.keys,
                  qualified: true,
                ),
          ].take(limit).toList(),
        );
      }

      final reference = aliases[qualifier.toLowerCase()];
      if (reference == null) return const SqlAutocompleteResult();
      final table = findTable(schemas, reference.schema, reference.table);
      if (table == null) return const SqlAutocompleteResult();
      if (!table.columnsLoaded) {
        return SqlAutocompleteResult(
          metadataRequest: SqlMetadataRequest.table(reference.schema, table),
        );
      }

      return SqlAutocompleteResult(
        options: [
          for (final column in table.columns)
            if (column.name.toLowerCase().startsWith(suffix))
              SqlCompletion(
                label: '$qualifier.${column.name}',
                detail: column.displayType,
                text: sql.replaceRange(
                  tokenStart,
                  safeCursor,
                  '$qualifier.${column.name}',
                ),
                cursorOffset:
                    tokenStart + qualifier.length + column.name.length + 1,
              ),
        ].take(limit).toList(),
      );
    }

    final options = <SqlCompletion>[];
    for (final keyword in _keywords) {
      if (keyword.toLowerCase().startsWith(lowerToken)) {
        options.add(
          SqlCompletion(
            label: keyword,
            detail: 'SQL keyword',
            text: sql.replaceRange(tokenStart, safeCursor, keyword),
            cursorOffset: tokenStart + keyword.length,
          ),
        );
      }
    }

    for (final schema in schemas) {
      if (schema.name.toLowerCase().startsWith(lowerToken)) {
        options.add(
          SqlCompletion(
            label: schema.name,
            detail: 'Schema',
            text: sql.replaceRange(tokenStart, safeCursor, schema.name),
            cursorOffset: tokenStart + schema.name.length,
          ),
        );
      }
      for (final table in schema.tables) {
        final qualifiedName = '${schema.name}.${table.name}';
        if (table.name.toLowerCase().startsWith(lowerToken) ||
            qualifiedName.toLowerCase().startsWith(lowerToken)) {
          options.add(
            _tableCompletion(
              sql: sql,
              cursor: safeCursor,
              tokenStart: tokenStart,
              schema: schema.name,
              table: table.name,
              aliases: aliases.keys,
              qualified: false,
            ),
          );
        }
      }
    }

    return SqlAutocompleteResult(options: options.take(limit).toList());
  }

  Map<String, SqlTableReference> aliasesIn(String sql) {
    final aliases = <String, SqlTableReference>{};
    final pattern = RegExp(
      r'\b(?:from|join)\s+(?:(\w+)\.)?(\w+)\s+(?:as\s+)?(\w+)',
      caseSensitive: false,
    );
    const reserved = {
      'where',
      'join',
      'left',
      'right',
      'inner',
      'outer',
      'full',
      'cross',
      'order',
      'group',
      'limit',
      'on',
      'union',
    };
    for (final match in pattern.allMatches(sql)) {
      final alias = match.group(3)?.toLowerCase();
      if (alias == null || reserved.contains(alias)) continue;
      aliases[alias] = SqlTableReference(
        schema: match.group(1),
        table: match.group(2)!,
      );
    }
    return aliases;
  }

  DatabaseTable? findTable(
    List<DatabaseSchema> schemas,
    String? schemaName,
    String tableName,
  ) {
    for (final schema in schemas) {
      if (schemaName != null &&
          schema.name.toLowerCase() != schemaName.toLowerCase()) {
        continue;
      }
      for (final table in schema.tables) {
        if (table.name.toLowerCase() == tableName.toLowerCase()) return table;
      }
    }
    return null;
  }

  SqlCompletion _tableCompletion({
    required String sql,
    required int cursor,
    required int tokenStart,
    required String schema,
    required String table,
    required Iterable<String> aliases,
    required bool qualified,
  }) {
    final alias = tableAlias(table, aliases);
    final name = qualified ? '$schema.$table' : table;
    final insertion = '$name $alias';
    return SqlCompletion(
      label: qualified ? name : table,
      detail: 'Table  ->  $insertion',
      text: sql.replaceRange(tokenStart, cursor, insertion),
      cursorOffset: tokenStart + insertion.length,
      schema: schema,
      table: table,
    );
  }

  String tableAlias(String tableName, Iterable<String> existingAliases) {
    final parts = tableName
        .split(RegExp(r'[_\W]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    var alias = parts.length > 1
        ? parts.map((part) => part[0]).join()
        : tableName.substring(0, tableName.length.clamp(1, 2));
    alias = alias.toLowerCase();
    final existing = existingAliases.map((item) => item.toLowerCase()).toSet();
    if (!existing.contains(alias)) return alias;
    var suffix = 2;
    while (existing.contains('$alias$suffix')) {
      suffix++;
    }
    return '$alias$suffix';
  }
}

class SqlTableReference {
  final String? schema;
  final String table;

  const SqlTableReference({required this.schema, required this.table});
}
