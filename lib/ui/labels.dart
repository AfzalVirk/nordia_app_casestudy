String statusLabel(String s) => switch (s) {
  'todo' => 'To do',
  'doing' => 'In progress',
  'done' => 'Done',
  _ => s,
};
