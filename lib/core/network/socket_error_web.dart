/// Browsers report network problems as http.ClientException, handled
/// elsewhere; there is no SocketException on the web.
bool isSocketError(Object error) => false;
