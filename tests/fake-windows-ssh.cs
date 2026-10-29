// Offline Windows test helper. Not an SSH server/client.
// With -N, hold a loopback TCP listener so the real tunnel lifecycle can be tested.
// Otherwise report the actual argv/stdin received by ProcessStartInfo.
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

class FakeSsh {
    static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("FAKE_SSH_FAIL") == "1") return 255;
        if (Array.IndexOf(args, "-N") >= 0) {
            int index = Array.IndexOf(args, "-L");
            int port = int.Parse(args[index + 1].Split(':')[1]);
            TcpListener listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            while (true) {
                using (TcpClient client = listener.AcceptTcpClient()) {}
                Thread.Sleep(10);
            }
        }
        foreach (string arg in args)
            Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        Console.WriteLine("stdin:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Console.In.ReadToEnd())));
        return 0;
    }
}
