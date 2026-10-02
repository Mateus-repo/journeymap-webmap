import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Reproduces Fabric Loader's nested-jar scan so a broken jar-in-jar is caught here
 * instead of at game launch.
 *
 * Fabric does ModDiscoverer$ModScanTask.computeJarStream -> java.util.zip.ZipInputStream
 * over the nested jar bytes, which is far stricter than .NET's ZipArchive: it rejects
 * "only DEFLATED entries can have EXT descriptor". This walks both archives the same
 * way and reads every entry to the end, so the same failure surfaces.
 *
 * Run:  java ZipJarCheck.java <mod.jar>
 */
public class ZipJarCheck {

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: java ZipJarCheck.java <mod.jar>");
            System.exit(2);
        }
        Path jar = Path.of(args[0]);
        System.out.println("checking " + jar.getFileName());

        int topEntries = 0;
        byte[] nestedBytes = null;
        String nestedName = null;

        // pass 1 - the outer jar, exactly like Fabric reads it
        try (ZipInputStream zin = new ZipInputStream(Files.newInputStream(jar))) {
            ZipEntry e;
            while ((e = zin.getNextEntry()) != null) {
                topEntries++;
                if (e.getName().startsWith("META-INF/jars/webmap-client")
                        && e.getName().endsWith(".jar")) {
                    nestedName = e.getName();
                    nestedBytes = readFully(zin);
                }
            }
        }
        System.out.println("  outer entries scanned : " + topEntries);

        if (nestedBytes == null) {
            System.out.println("  nested jar             : NOT FOUND");
            System.exit(1);
        }
        System.out.println("  nested jar             : " + nestedName
                + " (" + nestedBytes.length + " bytes)");

        // pass 2 - the nested jar, this is where Fabric blew up
        int nestedEntries = 0;
        int totalBytes = 0;
        boolean hasWebRootDir = false;
        try (ZipInputStream zin = new ZipInputStream(new ByteArrayInputStream(nestedBytes))) {
            ZipEntry e;
            while ((e = zin.getNextEntry()) != null) {
                nestedEntries++;
                // Javalin resolves the web root as a classpath *directory*, so the
                // archive has to actually carry the directory entry, not just files.
                if (e.getName().equals("assets/journeymap/web/")) hasWebRootDir = true;
                totalBytes += readFully(zin).length;
            }
        }
        System.out.println("  nested entries scanned : " + nestedEntries);
        System.out.println("  nested bytes inflated  : " + totalBytes);
        System.out.println("  web root dir entry     : " + hasWebRootDir);

        // the frontend we injected must be in there
        boolean hasIndex = false, hasBundle = false;
        try (ZipInputStream zin = new ZipInputStream(new ByteArrayInputStream(nestedBytes))) {
            ZipEntry e;
            while ((e = zin.getNextEntry()) != null) {
                if (e.getName().equals("assets/journeymap/web/index.html")) hasIndex = true;
                if (e.getName().equals("assets/journeymap/web/bundled/bundle.js")) hasBundle = true;
            }
        }
        System.out.println("  has index.html         : " + hasIndex);
        System.out.println("  has bundle.js          : " + hasBundle);

        if (!hasIndex || !hasBundle || !hasWebRootDir) {
            System.out.println("FAIL: nested frontend incomplete (index=" + hasIndex
                    + " bundle=" + hasBundle + " webrootdir=" + hasWebRootDir + ")");
            System.exit(1);
        }
        System.out.println();
        System.out.println("OK - both archives parse with java.util.zip.ZipInputStream");
    }

    private static byte[] readFully(InputStream in) throws IOException {
        return in.readAllBytes();
    }
}