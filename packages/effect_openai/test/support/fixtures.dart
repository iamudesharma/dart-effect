// Synthetic wire responses, independent of the adapter implementation.
Map<String, Object?> responseJson({String status = 'completed'}) => {
  'id': 'resp_fixture',
  'object': 'response',
  'created_at': 1,
  'status': status,
  'model': 'fixture-model',
  'output': [
    {
      'type': 'message',
      'id': 'msg_fixture',
      'role': 'assistant',
      'status': 'completed',
      'content': [
        {'type': 'output_text', 'text': 'Hello Effect', 'annotations': []},
      ],
    },
  ],
};

Map<String, Object?> chatJson() => {
  'id': 'chat_fixture',
  'object': 'chat.completion',
  'created': 1,
  'model': 'fixture-model',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': 'Hello chat'},
      'finish_reason': 'stop',
    },
  ],
};

Map<String, Object?> embeddingJson() => {
  'object': 'list',
  'model': 'fixture-embedding',
  'data': [
    {
      'object': 'embedding',
      'index': 0,
      'embedding': [0.25, -0.5],
    },
  ],
  'usage': {'prompt_tokens': 2, 'total_tokens': 2},
};
