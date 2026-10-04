/// The three states every async screen must model: loading, loaded (which
/// may itself be empty), and error. Every screen that fetches data should
/// hold a `ViewState<T>` and render through `AsyncStateView` so loading /
/// empty / error look and behave identically everywhere in the app.
sealed class ViewState<T> {
  const ViewState();
}

class ViewLoading<T> extends ViewState<T> {
  const ViewLoading();
}

class ViewData<T> extends ViewState<T> {
  final T data;
  const ViewData(this.data);
}

class ViewError<T> extends ViewState<T> {
  final String message;
  const ViewError(this.message);
}
