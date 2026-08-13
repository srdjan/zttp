import { fetchSync } from "zttp:io";

function handler(req: Request): Response {
    const city = req.query.city;
    if (!city) {
        return Response.json({ error: "city query parameter required" });
    }

    const url = `https://api.open-meteo.com/v1/forecast?latitude=0&longitude=0&current_weather=temp_2m&city=${encodeURIComponent(city)}`;

    const response = fetchSync(url);

    if (!response.ok) {
        return Response.json({ error: "Failed to fetch weather data" });
    }

    return Response.json(response.json());
}
