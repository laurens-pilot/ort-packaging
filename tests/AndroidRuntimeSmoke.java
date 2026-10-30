import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.util.Collections;

public final class AndroidRuntimeSmoke {
  public static void main(String[] args) throws Exception {
    System.setProperty("onnxruntime.native.path", args[1]);
    try (OrtEnvironment environment = OrtEnvironment.getEnvironment();
        OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
      for (int iteration = 0; iteration < 8; iteration++) {
        try (OrtSession session = environment.createSession(args[0], options);
            OnnxTensor input =
                OnnxTensor.createTensor(environment, new float[][] {{1, 2}, {3, 4}, {5, 6}});
            OrtSession.Result result = session.run(Collections.singletonMap("X", input))) {
          float[][] actual = (float[][]) result.get(0).getValue();
          if (actual.length != 3) throw new IllegalStateException("Incorrect output shape");
          for (int row = 0; row < 3; row++) {
            if (actual[row].length != 2) throw new IllegalStateException("Incorrect output shape");
            for (int column = 0; column < 2; column++) {
              float expected = row * 2 + column + 1;
              if (!Float.isFinite(actual[row][column])
                  || Math.abs(actual[row][column] - expected * expected) > 1e-5f) {
                throw new IllegalStateException("Incorrect JNI inference result");
              }
            }
          }
        }
      }
    }
    try (PrintStream output = new PrintStream(new FileOutputStream(FileDescriptor.out))) {
      output.println("JAVA_JNI_INFERENCE=passed");
    }
  }
}
