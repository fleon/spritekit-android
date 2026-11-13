package com.fleon.switchlings;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;

/**
 * Hands the share sheet's chosen app a share film the game wrote, read-only.
 *
 * <p>The same contract as androidx's {@code FileProvider}, for one
 * directory and without the dependency (this project has no androidx):
 * {@code content://<package>.films/<path>} names a file under the app's
 * cache directory, which is where Foundation's temporary directory points
 * on Android and so where {@code SolutionFilm} writes. Nothing outside it
 * can be named, nothing can be written, and a reader needs the grant the
 * share intent carries.
 */
public class FilmProvider extends ContentProvider {
    static String authority(android.content.Context context) {
        return context.getPackageName() + ".films";
    }

    /** The URI for {@code file}, which must lie under the cache directory. */
    static Uri uriFor(android.content.Context context, File file) throws IOException {
        String root = context.getCacheDir().getCanonicalPath() + File.separator;
        String path = file.getCanonicalPath();
        if (!path.startsWith(root)) {
            throw new IOException(path + " is not under the cache directory");
        }
        Uri.Builder builder = new Uri.Builder().scheme("content").authority(authority(context));
        for (String segment : path.substring(root.length()).split(File.separator)) {
            builder.appendPath(segment);
        }
        return builder.build();
    }

    private File fileFor(Uri uri) throws FileNotFoundException {
        try {
            File root = getContext().getCacheDir().getCanonicalFile();
            File file = new File(root, uri.getPath()).getCanonicalFile();
            if (!file.getPath().startsWith(root.getPath() + File.separator) || !file.isFile()) {
                throw new FileNotFoundException(uri.toString());
            }
            return file;
        } catch (IOException e) {
            throw new FileNotFoundException(uri.toString());
        }
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) {
            throw new FileNotFoundException("share films are read-only");
        }
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        String path = uri.getPath() == null ? "" : uri.getPath();
        if (path.endsWith(".mp4")) return "video/mp4";
        if (path.endsWith(".png")) return "image/png";
        return "application/octet-stream";
    }

    /** The name and size share targets ask for before they read. */
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        File file;
        try {
            file = fileFor(uri);
        } catch (FileNotFoundException e) {
            return null;
        }
        String[] columns = projection != null ? projection : new String[] { OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE };
        MatrixCursor cursor = new MatrixCursor(columns, 1);
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = file.getName();
            else if (OpenableColumns.SIZE.equals(columns[i])) row[i] = file.length();
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("share films are read-only");
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("share films are read-only");
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("share films are read-only");
    }
}
