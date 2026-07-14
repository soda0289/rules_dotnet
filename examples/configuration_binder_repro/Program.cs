using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;

var builder = WebApplication.CreateBuilder(args);

// This call is intercepted by the Microsoft.Extensions.Configuration.Binder
// source generator. It forces the generator to emit BindingExtensions.g.cs,
// which defines the InterceptsLocationAttribute type. The generator is supplied
// twice - once by the "web" targeting pack (Microsoft.AspNetCore.App.Ref) and
// once by the Microsoft.Extensions.Configuration.Binder NuGet package - so the
// type is emitted twice and the compile fails with CS0433.
var opts = builder.Configuration.GetSection("My").Get<MyOptions>();
System.Console.WriteLine(opts?.Name);

var app = builder.Build();
app.Run();

public class MyOptions
{
    public string Name { get; set; } = "";
    public int Count { get; set; }
}
