import 'dart:io';

/// True for "can't reach the network" errors on phones.
bool isSocketError(Object error) => error is SocketException;
